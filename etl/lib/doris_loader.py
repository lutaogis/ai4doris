#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
doris_loader.py —— 极简 Stream Load 客户端（只用标准库，无需 pip 安装）

设计要点（对应 docs/etl-guide.md §4）：
1. label 必须由调用方传入；重试复用同一 label → 天然幂等（§4.1）
2. "Label Already Exists" 视为成功，不当异常抛
3. 只信返回体的 Status 字段，HTTP 200 不代表导入成功
4. 失败时把 ErrorURL 里的脏数据落盘，便于定位（§4.5）

用法：
    from doris_loader import DorisLoader

    loader = DorisLoader(
        be_hosts=["192.168.1.54:8040", "192.168.1.55:8040", "192.168.1.56:8040"],
        user="root", password="Doris@2026", database="ods",
    )
    with open("/tmp/work_order.csv", "rb") as f:
        result = loader.load(
            table="ods_mes_work_order",
            body=f,
            label="ods_ods_mes_work_order_p20261101_20261101103000",
            columns="stat_date,wo_no,line_code,product_code,plan_qty,finish_qty",
            max_filter_ratio=0.01,
        )
    print(result["NumberLoadedRows"], result["NumberFilteredRows"])
"""

from __future__ import annotations

import base64
import http.client
import json
import os
import random
import time
from urllib.parse import urlparse

__all__ = ["DorisLoader", "DorisLoadError"]


class DorisLoadError(RuntimeError):
    """导入失败。result 里保留 Doris 原始返回，便于排查。"""

    def __init__(self, message: str, result: dict | None = None):
        super().__init__(message)
        self.result = result or {}


class DorisLoader:
    def __init__(
        self,
        be_hosts: list[str],
        user: str = "root",
        password: str = "",
        database: str = "",
        timeout: int = 1800,
        retries: int = 3,
    ):
        if not be_hosts:
            raise ValueError("be_hosts 不能为空，例如 ['192.168.1.54:8040', ...]")

        self.be_hosts: list[tuple[str, int]] = []
        for item in be_hosts:
            item = item.strip()
            if not item:
                continue
            if ":" in item:
                host, port = item.rsplit(":", 1)
                self.be_hosts.append((host, int(port)))
            else:
                self.be_hosts.append((item, 8040))
        if not self.be_hosts:
            raise ValueError("be_hosts 解析后为空")

        self.user = user
        self.password = password
        self.database = database
        self.timeout = timeout
        self.retries = retries
        token = base64.b64encode(f"{user}:{password}".encode()).decode()
        self._auth = f"Basic {token}"

    # ------------------------------------------------------------------ 公共入口
    def load(
        self,
        table: str,
        body,
        label: str,
        db: str | None = None,
        fmt: str = "csv",
        columns: str | None = None,
        max_filter_ratio: float = 0.01,
        strict_mode: bool = False,
        partition: str | None = None,
        extra_headers: dict | None = None,
    ) -> dict:
        """执行一次 Stream Load。

        参数
        ----
        body : bytes 或 已打开的文件对象（需可 seek）
        label : 批次唯一标识。重试用同一个 label，不要重新生成，否则会重复写入。
        columns : "c1,c2,c3" 或带表达式 "c1,c2,dt=now()"
        partition : 指定目标分区名（可选，不传则按数据自动路由）
        """
        database = db or self.database
        if not database:
            raise ValueError("未指定 database")
        if not label:
            raise ValueError("label 必须显式传入，随机 label 会失去幂等性")
        if len(label) > 128:
            raise ValueError(f"label 过长（{len(label)}），Doris 上限 128 字符")

        headers = {
            "Authorization": self._auth,
            "label": label,
            "format": fmt,
            "max_filter_ratio": str(max_filter_ratio),
            "strict_mode": "true" if strict_mode else "false",
            "timeout": str(self.timeout),
        }
        if columns:
            headers["columns"] = columns
        if partition:
            headers["partition"] = partition
        if extra_headers:
            headers.update({str(k): str(v) for k, v in extra_headers.items()})

        # 计算 Content-Length，并记住起始偏移以便重试时复位
        if isinstance(body, (bytes, bytearray)):
            length = len(body)
            start = None
        else:
            try:
                start = body.tell()
                body.seek(0, os.SEEK_END)
                length = body.tell() - start
                body.seek(start)
            except (AttributeError, OSError) as exc:
                raise ValueError("文件对象必须可 seek，才能计算 Content-Length") from exc
            if length <= 0:
                raise ValueError("待导入内容为空")

        last_error: Exception | None = None
        for attempt in range(1, self.retries + 1):
            host, port = random.choice(self.be_hosts)
            path = f"/api/{database}/{table}/_stream_load"
            if start is not None:
                body.seek(start)

            try:
                code, location, text = self._put(host, port, path, headers, body, length)
                # 命中 FE 端点时会被重定向到某个 BE，跟随一次
                if code in (301, 302, 307, 308) and location:
                    p = urlparse(location)
                    if p.hostname:
                        if start is not None:
                            body.seek(start)
                        new_path = p.path + (("?" + p.query) if p.query else "")
                        code, _, text = self._put(
                            p.hostname, p.port or 8040, new_path, headers, body, length
                        )
            except Exception as exc:  # 网络类错误，重试
                last_error = exc
                time.sleep(min(2 ** attempt, 10))
                continue

            try:
                result = json.loads(text)
            except ValueError:
                raise DorisLoadError(f"HTTP {code}，返回非 JSON：{text[:300]}") from None

            if code not in (200, 201):
                raise DorisLoadError(
                    f"HTTP {code}：{result.get('Message') or text[:300]}", result
                )

            status = str(result.get("Status") or "").lower()
            message = str(result.get("Message") or "")

            if status == "success":
                return result

            low = message.lower()
            # Doris 不同版本提示词不同，三种都要认：
            #   [LABEL_ALREADY_EXISTS]Label [xxx] has already been used
            #   Label already exists
            if (
                "label_already_exists" in low
                or "label already exist" in low
                or "has already been used" in low
            ):
                # 同一 label 已经成功导入过 → 幂等返回
                return dict(result, Status="Success", Duplicated=True)

            if status == "publish timeout":
                # 事务已提交，publish 尚未完成；稍等后用同一 label 再问一次
                last_error = DorisLoadError(f"Publish Timeout：{message}", result)
                time.sleep(3)
                continue

            if "too many versions" in low or "err=-235" in low:
                raise DorisLoadError(
                    "版本堆积（E-235）：减少导入频次 / 合并小批 / "
                    "执行 ALTER TABLE <t> COMPACT",
                    result,
                )

            raise DorisLoadError(f"导入失败（Status={status}）：{message}", result)

        raise DorisLoadError(f"重试 {self.retries} 次仍失败：{last_error}", None)

    # ------------------------------------------------------------------ 死信保存
    def save_error_rows(self, result: dict, out_dir: str = "/tmp/doris_error") -> str | None:
        """把 ErrorURL 里的过滤行下载到本地，返回文件路径。"""
        url = result.get("ErrorURL")
        if not url:
            return None
        p = urlparse(url)
        if not p.hostname:
            return None
        os.makedirs(out_dir, exist_ok=True)
        label = result.get("Label") or str(int(time.time()))
        out_path = os.path.join(out_dir, f"{label}.error.csv")

        conn = http.client.HTTPConnection(p.hostname, p.port or 8040, timeout=60)
        try:
            path = p.path + (("?" + p.query) if p.query else "")
            conn.request("GET", path, headers={"Authorization": self._auth})
            resp = conn.getresponse()
            data = resp.read()
        finally:
            conn.close()

        if resp.status != 200:
            return None
        with open(out_path, "wb") as f:
            f.write(data)
        return out_path

    # ------------------------------------------------------------------ 底层
    def _put(self, host, port, path, headers, body, length):
        conn = http.client.HTTPConnection(host, port, timeout=self.timeout)
        h = dict(headers)
        if length is not None:
            h["Content-Length"] = str(length)
        try:
            conn.request("PUT", path, body=body, headers=h)
            resp = conn.getresponse()
            raw = resp.read()
            return resp.status, resp.getheader("Location"), raw.decode("utf-8", "replace")
        finally:
            conn.close()
