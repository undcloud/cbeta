#!/usr/bin/env python3
"""遞迴抓取 CBETA Online「部類、冊別、作譯者、年代」目錄。

預設優先呼叫 https://cbetaonline.dila.edu.tw/zh-tw/mobile/ 所使用的官方 API
(https://cbdata.dila.edu.tw/stable)。若 API 主機不可達，改用 API 匯入來源的
官方上游靜態資料重建同一份目錄：

  * 部類/冊別：heavenchou/cbwork-bin 的 bulei.txt、advance_nav.txt
  * 作品/作譯者/年代：DILA-edu/Authority-Databases 的 authority_catalog/json
  * 年代順序：DILA-edu/cbeta-api 的 data-static/dynasty-order.csv
  * 作譯者別名：Authority-Databases 的 Buddhist_Studies_Person_Authority.xml

所有 HTTP 請求皆為單執行緒、逐一送出；預設每次間隔 2.2 秒，並同時套用
「每 60 秒最多 30 次、每 1 秒最多 4 次」的滑動視窗限制。

輸出（預設寫入 assets/cbeta_catalog/）：
  catalog.json     部類樹與冊別樹（節點順序與 API 的 sort 相同）
  creators.json    作譯者清單、別名與各作譯者作品
  dynasties.json   年代清單、西元年範圍、部數與作品
  works.json       作品中繼資料（卷數、檔案、作譯者、朝代）
  work_files.json  作品編號對應的檔名
  manifest.json    來源、限速、筆數與警告
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from xml.etree import ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / "assets" / "cbeta_catalog"
DEFAULT_CACHE = ROOT / "tool" / ".catalog_cache"

API_BASE = "https://cbdata.dila.edu.tw/stable"
MOBILE_PAGE = "https://cbetaonline.dila.edu.tw/zh-tw/mobile/"
CBWORK_BASE = "https://raw.githubusercontent.com/heavenchou/cbwork-bin/master/cbreader2X"
AUTHORITY_BASE = "https://raw.githubusercontent.com/DILA-edu/Authority-Databases/master"
CBETA_API_BASE = "https://raw.githubusercontent.com/DILA-edu/cbeta-api/master"

# 這些鏡像只用於小於 20 MB 的檔案；person XML 直接走 raw.githubusercontent.com。
MIRRORS = (
    "https://cdn.jsdelivr.net/gh/{owner}/{repo}@master/{path}",
    "https://raw.githubusercontent.com/{owner}/{repo}/master/{path}",
)

CANONS = (
    "A", "B", "C", "CC", "D", "F", "G", "GA", "GB", "I", "J", "K", "L",
    "LC", "M", "N", "P", "S", "T", "TX", "U", "X", "Y", "YP", "ZS", "ZW",
)

WORK_RE = re.compile(r"^([A-Z]{1,3}\d{3,5}[A-Za-z]?)(?:\s|$)")
JUAN_RE = re.compile(r"^([A-Z]{1,3}\d{3,5}[A-Za-z]?)_(\d{3})(?:\.\.(\d{3}))?$")
LINEHEAD_RE = re.compile(r"^([A-Z]{1,3}\d{2,3})n(.{5})p([a-z\d]\d{3}[a-z]\d+)$")
CANON_RE = re.compile(r"^[A-Z]{1,3}$")
CANON_PREFIX_RE = re.compile(r"^([A-Z]{1,3}) ")
ENTITY_RE = re.compile(r"&(?:CB|M)\d+;")
JUAN_LABEL_RE = re.compile(r"(?:第\s*(\d+)\s*卷|\(卷\s*(\d+)(?:\s*[-–~]\s*(\d+))?\)|卷\s*(\d+)(?:\s*[-–~]\s*(\d+))?)")


class CrawlError(RuntimeError):
    pass


class SerialRateLimiter:
    """嚴格串行限速器：任何時刻最多一個請求。"""

    def __init__(
        self,
        min_interval: float = 2.2,
        per_minute: int = 30,
        per_second: int = 4,
    ) -> None:
        self.min_interval = min_interval
        self.per_minute = per_minute
        self.per_second = per_second
        self._last = 0.0
        self._stamps: list[float] = []

    def wait(self) -> None:
        now = time.monotonic()
        delay = self._last + self.min_interval - now
        if delay > 0:
            time.sleep(delay)
        while True:
            now = time.monotonic()
            self._stamps = [t for t in self._stamps if now - t < 60.0]
            last_second = sum(1 for t in self._stamps if now - t < 1.0)
            if len(self._stamps) < self.per_minute and last_second < self.per_second:
                break
            time.sleep(0.2)
        self._stamps.append(now)
        self._last = now


class Fetcher:
    def __init__(
        self,
        cache_dir: Path,
        limiter: SerialRateLimiter,
        log_path: Path,
        offline: bool = False,
    ) -> None:
        self.cache_dir = cache_dir
        self.limiter = limiter
        self.log_path = log_path
        self.offline = offline
        self.records: list[dict[str, object]] = []
        log_path.parent.mkdir(parents=True, exist_ok=True)
        self._log = log_path.open("a", encoding="utf-8")

    def close(self) -> None:
        self._log.close()

    def _record(self, url: str, status: str, extra: str = "") -> None:
        line = f"{datetime.now(timezone.utc).isoformat()}\t{status}\t{url}\t{extra}"
        self._log.write(line + "\n")
        self._log.flush()
        self.records.append({"url": url, "status": status, "detail": extra})
        print(f"[{status}] {url} {extra}".rstrip(), flush=True)

    def get_bytes(
        self,
        url: str,
        *,
        cache_path: Path | None = None,
        timeout: float = 90.0,
        attempts: int = 3,
        allow_404: bool = False,
    ) -> bytes | None:
        if cache_path is not None and cache_path.exists():
            data = cache_path.read_bytes()
            if data:
                self._record(url, "CACHE", f"{len(data)} bytes")
                return data
        if self.offline:
            raise CrawlError(f"offline 模式找不到快取：{cache_path or url}")

        last_error: Exception | None = None
        for attempt in range(1, attempts + 1):
            self.limiter.wait()
            request = urllib.request.Request(
                url,
                headers={
                    "User-Agent": "xuefo-catalog-crawler/1.0 (+https://cbetaonline.dila.edu.tw/)",
                    "Accept-Encoding": "identity",
                },
            )
            try:
                with urllib.request.urlopen(request, timeout=timeout) as response:
                    data = response.read()
                    self._record(url, "OK", f"{len(data)} bytes")
                    if cache_path is not None:
                        cache_path.parent.mkdir(parents=True, exist_ok=True)
                        tmp = cache_path.with_suffix(cache_path.suffix + ".part")
                        tmp.write_bytes(data)
                        tmp.replace(cache_path)
                    return data
            except urllib.error.HTTPError as error:
                last_error = error
                if error.code == 404 and allow_404:
                    self._record(url, "404")
                    return None
                self._record(url, f"HTTP{error.code}", f"attempt {attempt}")
                if error.code in (400, 401, 403, 404):
                    break
            except Exception as error:  # noqa: BLE001 - 記錄後重試
                last_error = error
                self._record(url, "ERROR", f"attempt {attempt}: {error}")
            if attempt < attempts:
                time.sleep(5.0 * attempt)
        raise CrawlError(f"下載失敗：{url}：{last_error}")

    def get_text(self, url: str, **kwargs: object) -> str:
        data = self.get_bytes(url, **kwargs)
        if data is None:
            raise CrawlError(f"找不到檔案：{url}")
        return data.decode("utf-8")

    def get_json(self, url: str, **kwargs: object) -> object:
        return json.loads(self.get_text(url, **kwargs))


@dataclass
class RawNode:
    text: str
    children: list["RawNode"] = field(default_factory=list)


@dataclass
class Work:
    n: str
    title: str
    vol: str
    juans: int
    byline: str = ""
    dynasty: str = ""
    time_from: int | None = None
    time_to: int | None = None
    category: str = ""
    orig_category: str = ""
    work_type: str = "textbody"
    contributors: list[dict[str, str]] = field(default_factory=list)
    alt: str = ""

    @property
    def file(self) -> str:
        return work_file(self)

    @property
    def juan_start(self) -> int:
        return 1

    @property
    def juan_list(self) -> str:
        return ",".join(str(i) for i in range(1, self.juans + 1))

    def to_hash(self, *, label: str | None = None) -> dict[str, object]:
        result: dict[str, object] = {
            "work": self.n,
            "canon": self.n[: len(re.match(r"^[A-Z]+", self.n).group(0))],
            "category": self.category,
            "orig_category": self.orig_category,
            "vol": self.vol,
            "title": self.title,
            "juan": self.juans,
            "juan_list": self.juan_list,
            "file": self.file,
            "juan_start": self.juan_start,
            "byline": self.byline,
            "creators": ",".join(c["name"] for c in self.contributors),
            "creators_with_id": ";".join(
                f"{c['name']}({c['id']})" for c in self.contributors if c.get("id")
            ),
            "time_dynasty": self.dynasty,
        }
        if self.time_from is not None:
            result["time_from"] = self.time_from
        if self.time_to is not None:
            result["time_to"] = self.time_to
        if label is not None:
            result["label"] = label
        return result


def work_file(work: Work) -> str:
    vol = work.vol.split("..")[0] if work.vol else ""
    return f"{vol}n{work.n[1:]}"


def normalize_juan(value: object) -> int:
    try:
        return int(str(value))
    except (TypeError, ValueError):
        return 1


def load_works_from_authority(raw: dict[str, dict[str, object]]) -> dict[str, Work]:
    works: dict[str, Work] = {}
    for work_id, info in raw.items():
        if not isinstance(info, dict):
            continue
        contributors = []
        for person in info.get("contributors") or []:
            if not isinstance(person, dict):
                continue
            name = str(person.get("name") or "").strip()
            if not name:
                continue
            entry = {"name": name}
            if person.get("id"):
                entry["id"] = str(person["id"])
            contributors.append(entry)
        works[work_id] = Work(
            n=work_id,
            title=str(info.get("title") or work_id),
            vol=str(info.get("vol") or ""),
            juans=normalize_juan(info.get("juans")),
            byline=str(info.get("byline") or ""),
            dynasty=str(info.get("dynasty") or ""),
            time_from=int(info["time_from"]) if info.get("time_from") is not None else None,
            time_to=int(info["time_to"]) if info.get("time_to") is not None else None,
            category=str(info.get("category") or ""),
            orig_category=str(info.get("orig_category") or ""),
            work_type=str(info.get("type") or "textbody"),
            contributors=contributors,
            alt=str(info.get("alt") or ""),
        )
    return works


def parse_catalog_text(text: str) -> RawNode:
    root = RawNode("")
    stack: list[tuple[RawNode, int]] = [(root, -1)]
    for line in text.splitlines():
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip("\t"))
        node_text = ENTITY_RE.sub("●", line.strip())
        node = RawNode(node_text)
        while stack and stack[-1][1] >= indent:
            stack.pop()
        stack[-1][0].children.append(node)
        stack.append((node, indent))
    return root


def juan_from_label(label: str) -> tuple[int | None, int | None]:
    match = JUAN_LABEL_RE.search(label)
    if not match:
        return None, None
    values = [g for g in match.groups() if g is not None]
    if not values:
        return None, None
    start = int(values[0])
    end = int(values[1]) if len(values) > 1 else start
    return start, end


class UpstreamBuilder:
    def __init__(
        self,
        works: dict[str, Work],
        warnings: list[str],
    ) -> None:
        self.works = works
        self.warnings = warnings
        self.by_vol: dict[str, list[Work]] = {}
        self.linehead_juan: dict[str, tuple[int, int]] = {}
        self.used_work_ids: set[str] = set()
        for work in works.values():
            self.by_vol.setdefault(work.vol, []).append(work)
        for entries in self.by_vol.values():
            entries.sort(key=lambda item: item.n)

    def serial(self, parent: str, index: int, text: str, level: int, catalog: str) -> str:
        if catalog == "orig" and level < 4:
            match = CANON_PREFIX_RE.match(text)
            if match and match.group(1) in CANONS:
                return f"orig-{match.group(1)}"
        return f"{parent}.{index:03d}"

    def build(self, text: str, n: str, label: str, catalog: str) -> dict[str, object]:
        raw = parse_catalog_text(text)
        items, consumed = self._walk(raw.children, n, 1, catalog)
        root = {
            "n": n,
            "label": label,
            "node_type": "root",
            "items": items,
        }
        self.assert_all_items_have_nodes(root)
        return root

    def assert_all_items_have_nodes(self, root: dict[str, object]) -> None:
        seen: set[str] = set()

        def walk(node: dict[str, object]) -> None:
            n = str(node.get("n"))
            if n in seen:
                raise CrawlError(f"節點編號重複：{n}")
            seen.add(n)
            for item in node.get("items", []):  # type: ignore[union-attr]
                if "items" in item:
                    walk(item)

        walk(root)

    def _walk(
        self,
        nodes: list[RawNode],
        parent: str,
        level: int,
        catalog: str,
    ) -> tuple[list[dict[str, object]], int]:
        items: list[dict[str, object]] = []
        index = 1
        for node in nodes:
            n = self.serial(parent, index, node.text, level, catalog)
            if node.children:
                child_items, _ = self._walk(node.children, n, level + 1, catalog)
                items.append(
                    {
                        "n": n,
                        "label": node.text,
                        "node_type": "category",
                        "sort": index,
                        "items": child_items,
                    }
                )
                index += 1
                continue

            text = node.text
            if CANON_RE.fullmatch(text) and text in CANONS:
                canon_works = sorted(
                    (w for w in self.works.values() if w.n.startswith(text)),
                    key=lambda item: item.n,
                )
                for work in canon_works:
                    item = self._add_work(parent, index, work, sort=index)
                    if item is not None:
                        items.append(item)
                        index += 1
                continue

            if " " in text:
                first, rest = text.split(" ", 1)
                if first.lower().endswith((".htm", ".html")):
                    items.append(
                        {
                            "n": n,
                            "label": rest,
                            "node_type": "html",
                            "file": first,
                            "sort": index,
                        }
                    )
                elif JUAN_RE.fullmatch(first):
                    match = JUAN_RE.fullmatch(first)
                    assert match is not None
                    work_id, j1, j2 = match.groups()
                    work = self.works.get(work_id)
                    if work is None:
                        self.warnings.append(f"{catalog}: 卷節點找不到作品 {work_id}（{text}）")
                    else:
                        start = int(j1)
                        end = int(j2) if j2 else start
                        self.used_work_ids.add(work_id)
                        items.append(
                            {
                                "n": n,
                                "label": rest,
                                "node_type": "work",
                                "work": work_id,
                                "file": work.file,
                                "juan_start": start,
                                "juan_end": end,
                                "sort": index,
                                "category": work.category,
                                "creators": ",".join(c["name"] for c in work.contributors),
                                "byline": work.byline,
                            }
                        )
                elif LINEHEAD_RE.fullmatch(first):
                    item = self._linehead_item(first, rest, n, index)
                    if item is not None:
                        items.append(item)
                elif WORK_RE.match(first):
                    work = self.works.get(first)
                    if work is None:
                        self.warnings.append(f"{catalog}: 找不到作品 {first}（{text}）")
                    else:
                        item = self._add_work(parent, index, work, sort=index)
                        if item is not None:
                            items.append(item)
                else:
                    self.warnings.append(f"{catalog}: 無法識別目錄行：{text}")
                index += 1
                continue

            expanded = self._expand_list(parent, index, text, catalog)
            items.extend(expanded)
            index += len(expanded)
        return items, index - 1

    def _linehead_item(
        self,
        linehead: str,
        label: str,
        n: str,
        index: int,
    ) -> dict[str, object] | None:
        match = LINEHEAD_RE.fullmatch(linehead)
        if match is None:
            self.warnings.append(f"無法解析行首資訊：{linehead}")
            return None
        vol_prefix, _digits, lb = match.groups()
        canon_match = re.match(r"^([A-Z]{1,3})(\d{2,3})n", vol_prefix)
        if canon_match is None:
            self.warnings.append(f"無法解析行首資訊：{linehead}")
            return None
        canon, _vol_digits = canon_match.groups()
        work_id = f"{canon}{_digits.removesuffix('_').zfill(4)}"
        work = self.works.get(work_id)
        if work is None:
            self.warnings.append(f"行首資訊找不到作品 {work_id}：{linehead}")
            return None
        start, end = juan_from_label(label)
        if start is None:
            start = work.juan_start
            end = start
        self.linehead_juan[linehead] = (start, end)
        self.used_work_ids.add(work_id)
        return {
            "n": n,
            "label": label,
            "node_type": "work",
            "work": work_id,
            "file": vol_prefix,
            "lb": lb,
            "juan_start": start,
            "juan_end": end,
            "sort": index,
            "category": work.category,
            "creators": ",".join(c["name"] for c in work.contributors),
            "byline": work.byline,
        }

    def _expand_list(
        self,
        parent: str,
        start_index: int,
        text: str,
        catalog: str,
    ) -> list[dict[str, object]]:
        result: list[dict[str, object]] = []
        for raw_item in text.split(","):
            item = raw_item.strip()
            if not item:
                continue
            if ".." in item:
                first, second = item.split("..", 1)
            else:
                first, second = item, None
            if WORK_RE.match(first):
                end = second or first
                for work in sorted(self.works.values(), key=lambda w: w.n):
                    if first <= work.n <= end:
                        built = self._add_work(
                            parent,
                            start_index + len(result),
                            work,
                            sort=start_index + len(result),
                        )
                        if built is not None:
                            result.append(built)
            elif re.fullmatch(r"[A-Z]{1,3}\d{2,3}", first):
                end = second or first
                candidates: list[Work] = []
                for vol, entries in self.by_vol.items():
                    if first <= vol <= end:
                        candidates.extend(entries)
                for work in sorted(candidates, key=lambda w: w.n):
                    built = self._add_work(
                        parent,
                        start_index + len(result),
                        work,
                        sort=start_index + len(result),
                    )
                    if built is not None:
                        result.append(built)
            else:
                self.warnings.append(f"{catalog}: 無法展開列表：{item}")
        return result

    def _add_work(
        self,
        parent: str,
        index: int,
        work: Work,
        *,
        sort: int,
    ) -> dict[str, object] | None:
        if work.alt:
            item: dict[str, object] = {
                "n": f"{parent}.{index:03d}",
                "label": self._alt_label(work),
                "node_type": "alt",
                "file": work.file,
                "sort": sort,
            }
            children: list[dict[str, object]] = []
            for alt_index, token in enumerate(work.alt.split("+"), start=1):
                child = self._alt_child(item["n"], alt_index, token)
                if child is not None:
                    children.append(child)
            if children:
                item["items"] = children
            return item

        self.used_work_ids.add(work.n)
        return {
            "n": f"{parent}.{index:03d}",
            "label": self._work_label(work),
            "node_type": "work",
            "work": work.n,
            "file": work.file,
            "sort": sort,
            "category": work.category,
            "creators": ",".join(c["name"] for c in work.contributors),
            "byline": work.byline,
        }

    def _work_label(self, work: Work) -> str:
        if work.n.startswith("Y"):
            return f"{work.n} {work.title}"
        return f"{work.n} {work.title} ({work.juans}卷)"

    def _alt_label(self, work: Work) -> str:
        label = f"{work.n}(={work.alt}) {work.title}"
        if not work.n.startswith(("LC", "TX", "Y")):
            label += f" ({work.juans}卷)"
        return label

    def _alt_child(
        self,
        parent_n: str,
        index: int,
        token: str,
    ) -> dict[str, object] | None:
        juan_range: tuple[int, int] | None = None
        lb = ""
        if len(token) <= 6:
            work_id = token
        else:
            match = LINEHEAD_RE.fullmatch(token)
            if match is None:
                self.warnings.append(f"無法解析 alt 行首資訊：{token}")
                return None
            vol_prefix, digits, lb = match.groups()
            canon_match = re.match(r"^([A-Z]{1,3})(\d{2,3})n", vol_prefix)
            if canon_match is None:
                self.warnings.append(f"無法解析 alt 行首資訊：{token}")
                return None
            canon, _vol = canon_match.groups()
            work_id = f"{canon}{digits.removesuffix('_').zfill(4)}"
            juan_range = self.linehead_juan.get(token)
        work = self.works.get(work_id)
        if work is None:
            self.warnings.append(f"alt 找不到作品 {work_id}：{token}")
            return None
        self.used_work_ids.add(work_id)
        if juan_range is None:
            label = self._work_label(work)
        else:
            start, end = juan_range
            label = f"{work_id} {work.title} ({start}~{end}卷)"
        child: dict[str, object] = {
            "n": f"{parent_n}.{index:03d}",
            "label": label,
            "node_type": "work",
            "work": work_id,
            "file": work.file,
            "sort": index,
            "category": work.category,
            "creators": ",".join(c["name"] for c in work.contributors),
            "byline": work.byline,
        }
        if lb:
            child["lb"] = lb
        if juan_range is not None:
            child["juan_start"] = juan_range[0]
            child["juan_end"] = juan_range[1]
        else:
            child["juan_start"] = work.juan_start
            child["juan_end"] = work.juan_start
        return child


def parse_person_authority(path: Path, warnings: list[str]) -> dict[str, dict[str, object]]:
    """從 person authority XML 取 regular_name / aliases_all。

    使用 iterparse，避免一次載入 50 MB XML。若檔案不完整（下載中斷），
    保留已解析的部分並記錄警告。
    """
    if not path.exists():
        warnings.append("缺少 person authority XML，作譯者別名留空")
        return {}
    people: dict[str, dict[str, object]] = {}
    try:
        context = ET.iterparse(path, events=("end",))
        for _event, element in context:
            if not element.tag.endswith("person"):
                continue
            person_id = element.get("{http://www.w3.org/XML/1998/namespace}id") or element.get("id")
            if not person_id:
                element.clear()
                continue
            regular = ""
            aliases: list[str] = []
            for name_node in element.iter():
                if not name_node.tag.endswith("persName"):
                    continue
                name = "".join(name_node.itertext()).strip()
                if not name:
                    continue
                name_type = name_node.get("type")
                if name_type == "alternative":
                    if name not in aliases:
                        aliases.append(name)
                elif not name_type and name_node.get("lang") == "zho-Hant" and not regular:
                    regular = name
            if regular:
                entry: dict[str, object] = {"regular_name": regular}
                if aliases:
                    entry["aliases_all"] = aliases
                people[person_id] = entry
            element.clear()
    except ET.ParseError as error:
        warnings.append(f"person authority XML 不完整，已解析 {len(people)} 人：{error}")
    return people


def build_creators(
    works: dict[str, Work],
    people: dict[str, dict[str, object]],
    import_order: list[str],
) -> dict[str, object]:
    bylines = [work.byline for work in works.values() if work.byline]

    def appears_in_byline(alias: str) -> bool:
        return any(alias in byline for byline in bylines)

    creators: dict[str, dict[str, object]] = {}
    creator_work_ids: dict[str, list[str]] = {}
    for work_id in import_order:
        work = works.get(work_id)
        if work is None:
            continue
        for contributor in work.contributors:
            person_id = contributor.get("id")
            if not person_id:
                continue
            if person_id not in creators:
                person = people.get(person_id, {})
                entry: dict[str, object] = {
                    "regular_name": person.get("regular_name") or contributor["name"],
                }
                aliases = person.get("aliases_all") or []
                if aliases:
                    entry["aliases_all"] = aliases
                    aliases_byline = [a for a in aliases if appears_in_byline(a)]
                    if aliases_byline:
                        entry["aliases_byline"] = aliases_byline
                creators[person_id] = entry
                creator_work_ids[person_id] = []
            if work_id not in creator_work_ids[person_id]:
                creator_work_ids[person_id].append(work_id)

    creator_works: dict[str, list[dict[str, object]]] = {}
    for person_id, ids in creator_work_ids.items():
        creator_works[person_id] = [
            works[work_id].to_hash(label=f"{works[work_id].n} {works[work_id].title}")
            for work_id in sorted(ids)
        ]

    return {
        "creators": dict(sorted(creators.items())),
        "works": dict(sorted(creator_works.items())),
    }


def build_dynasties(
    works: dict[str, Work],
    order_csv: str,
    warnings: list[str],
) -> list[dict[str, object]]:
    buckets: dict[str, list[Work]] = {}
    no_dynasty: list[Work] = []
    for work in works.values():
        if work.dynasty:
            buckets.setdefault(work.dynasty, []).append(work)
        else:
            no_dynasty.append(work)

    rows: list[dict[str, object]] = []
    reader = csv.DictReader(io.StringIO(order_csv))
    for row in reader:
        aliases = str(row.get("dynasty") or "").split("/")
        selected: list[Work] = []
        for alias in aliases:
            selected.extend(buckets.pop(alias, []))
        if not selected:
            continue
        selected.sort(key=lambda w: w.n)
        rows.append(
            {
                "name": str(row.get("dynasty")),
                "start": int(row.get("time_from") or 0),
                "end": int(row.get("time_to") or 0),
                "count": len(selected),
                "works": [
                    {
                        "work": work.n,
                        "label": f"{work.n} {work.title}",
                        "title": work.title,
                        "byline": work.byline,
                        "file": work.file,
                        "juan": work.juans,
                    }
                    for work in selected
                ],
            }
        )

    leftover = {name: items for name, items in buckets.items() if items}
    for name, items in sorted(leftover.items()):
        warnings.append(f"朝代不在 dynasty-order.csv：{name}（{len(items)} 部）")
    if no_dynasty:
        warnings.append(f"無朝代作品 {len(no_dynasty)} 部（API 不列入 dynasty-all.csv）")
    return rows


def flatten_catalog_refs(node: dict[str, object]) -> tuple[int, int, int]:
    categories = 0
    works_count = 0
    html = 0
    for item in node.get("items", []):  # type: ignore[union-attr]
        if item.get("node_type") == "html":
            html += 1
        elif "items" in item:
            categories += 1
            sub = flatten_catalog_refs(item)
            categories += sub[0]
            works_count += sub[1]
            html += sub[2]
        elif item.get("work"):
            works_count += 1
    return categories, works_count, html


def catalog_work_ids(node: dict[str, object]) -> set[str]:
    result: set[str] = set()
    for item in node.get("items", []):  # type: ignore[union-attr]
        work_id = item.get("work")
        if isinstance(work_id, str):
            result.add(work_id)
        if "items" in item:
            result.update(catalog_work_ids(item))
    return result


def count_catalog_nodes(node: dict[str, object]) -> int:
    total = 0
    for item in node.get("items", []):  # type: ignore[union-attr]
        total += 1
        if "items" in item:
            total += count_catalog_nodes(item)
    return total


def load_authority_works(
    fetcher: Fetcher,
    cache_dir: Path,
    warnings: list[str],
) -> tuple[dict[str, Work], list[str], list[dict[str, object]]]:
    works: dict[str, Work] = {}
    import_order: list[str] = []
    sources: list[dict[str, object]] = []
    for canon in CANONS:
        path = f"authority_catalog/json/{canon}.json"
        url = f"{AUTHORITY_BASE}/{path}"
        cache_path = cache_dir / "authority" / f"{canon}.json"
        try:
            payload = fetcher.get_json(url, cache_path=cache_path, allow_404=True)
        except CrawlError as error:
            warnings.append(f"讀取 {canon} 作品資料失敗：{error}")
            continue
        if payload is None:
            continue
        if not isinstance(payload, dict):
            warnings.append(f"{canon}.json 格式不是物件，已略過")
            continue
        for work_id in payload:
            if work_id not in works:
                import_order.append(work_id)
        works.update(load_works_from_authority(payload))
        sources.append(
            {
                "name": f"authority_catalog/{canon}.json",
                "url": url,
                "sha256": hashlib.sha256(cache_path.read_bytes()).hexdigest(),
                "works": len(payload),
            }
        )
    return works, import_order, sources


def crawl_api_catalog(
    fetcher: Fetcher,
    root: str,
    label: str,
    cache_dir: Path,
) -> dict[str, object]:
    counter = {"nodes": 0}

    def fetch_node(q: str, node_label: str) -> dict[str, object]:
        url = f"{API_BASE}/catalog_entry?q={urllib.parse.quote(q)}"
        safe_q = urllib.parse.quote(q, safe="")
        payload = fetcher.get_json(
            url,
            cache_path=cache_dir / "api" / "catalog" / f"{safe_q}.json",
        )
        if not isinstance(payload, dict):
            raise CrawlError(f"catalog_entry 回應格式錯誤：{q}")
        counter["nodes"] += 1
        if counter["nodes"] % 25 == 0:
            print(f"  已抓取 {counter['nodes']} 個目錄節點（目前 {q}）", flush=True)
        items: list[dict[str, object]] = []
        for raw in payload.get("results") or []:
            item = dict(raw)
            if item.get("work") or item.get("node_type") == "html":
                items.append(item)
            else:
                child = fetch_node(
                    str(item.get("n")), str(item.get("label") or item.get("n"))
                )
                item["items"] = child["items"]
                items.append(item)
        actual_label = str(payload.get("label") or node_label)
        return {"n": q, "label": actual_label, "node_type": "root", "items": items}

    result = fetch_node(root, label)
    print(f"  目錄 {root} 完成，共 {counter['nodes']} 個節點", flush=True)
    return result


def build_creators_from_api(
    api_list: dict[str, object],
    works: dict[str, Work],
    import_order: list[str],
) -> dict[str, object]:
    by_contributor: dict[str, list[str]] = {}
    for work_id in import_order:
        work = works.get(work_id)
        if work is None:
            continue
        for contributor in work.contributors:
            person_id = contributor.get("id")
            if person_id:
                by_contributor.setdefault(person_id, []).append(work_id)

    creators: dict[str, object] = {}
    creator_works: dict[str, list[dict[str, object]]] = {}
    for creator_id, info in api_list.items():
        if not isinstance(info, dict):
            continue
        creators[creator_id] = info
        creator_works[creator_id] = [
            works[work_id].to_hash(label=f"{works[work_id].n} {works[work_id].title}")
            for work_id in sorted(by_contributor.get(creator_id, []))
        ]
    return {
        "creators": dict(sorted(creators.items())),
        "works": dict(sorted(creator_works.items())),
    }


def fetch_api_dynasties(fetcher: Fetcher, cache_dir: Path) -> list[dict[str, object]]:
    cache_base = cache_dir / "api" / "dynasty"
    csv_text = fetcher.get_text(
        f"{API_BASE}/download/stat/dynasty-all.csv",
        cache_path=cache_base / "dynasty-all.csv",
    )
    rows: list[dict[str, object]] = []
    reader = csv.reader(io.StringIO(csv_text))
    for index, row in enumerate(reader):
        if index == 0 or len(row) < 4:
            continue
        name, start, end, count = row[:4]
        query = name.replace("/", ",")
        url = f"{API_BASE}/works?dynasty={urllib.parse.quote(query)}"
        cache_name = urllib.parse.quote(name.replace("/", "_"), safe="") + ".json"
        try:
            payload = fetcher.get_json(url, cache_path=cache_base / cache_name)
        except CrawlError:
            payload = {}
        works = payload.get("results") if isinstance(payload, dict) else []
        rows.append(
            {
                "name": name,
                "start": int(start),
                "end": int(end),
                "count": int(count),
                "works": works or [],
            }
        )
    return rows


def configure_sources(fetcher: Fetcher, cache_dir: Path) -> dict[str, str]:
    catalog_sources: dict[str, str] = {}
    for key, path in (
        ("bulei", "bulei/bulei.txt"),
        ("advance_nav", "nav/advance_nav.txt"),
    ):
        cache_path = cache_dir / "catalog" / f"{key}.txt"
        if cache_path.exists():
            catalog_sources[key] = cache_path.read_text(encoding="utf-8")
            fetcher._record("cbwork-bin/" + path, "CACHE")
            continue
        last_error: Exception | None = None
        for template in MIRRORS:
            url = template.format(owner="heavenchou", repo="cbwork-bin", path=path)
            try:
                text = fetcher.get_text(url, cache_path=cache_path)
                catalog_sources[key] = text
                last_error = None
                break
            except CrawlError as error:
                last_error = error
        if last_error is not None:
            raise last_error
    return catalog_sources


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--cache-dir", type=Path, default=DEFAULT_CACHE)
    parser.add_argument(
        "--mode",
        choices=("auto", "api", "upstream", "offline"),
        default="auto",
        help="auto：先試官方 API，不可達改用上游；offline：只讀快取",
    )
    parser.add_argument("--min-interval", type=float, default=2.2)
    parser.add_argument("--max-per-minute", type=int, default=30)
    parser.add_argument("--max-per-second", type=int, default=4)
    parser.add_argument(
        "--person-xml",
        type=Path,
        default=None,
        help="可指定已下載完整的 person authority XML",
    )
    args = parser.parse_args()

    args.output.mkdir(parents=True, exist_ok=True)
    args.cache_dir.mkdir(parents=True, exist_ok=True)
    warnings: list[str] = []
    limiter = SerialRateLimiter(
        min_interval=args.min_interval,
        per_minute=args.max_per_minute,
        per_second=args.max_per_second,
    )
    fetcher = Fetcher(
        args.cache_dir,
        limiter,
        args.cache_dir / "crawl.log",
        offline=args.mode == "offline",
    )

    api_state: dict[str, object] = {"base": API_BASE, "reachable": False}
    category_tree: dict[str, object] | None = None
    volume_tree: dict[str, object] | None = None
    api_creators: dict[str, object] | None = None
    api_creator_list: dict[str, object] | None = None
    api_dynasties: list[dict[str, object]] | None = None
    mode_used = "upstream"
    used_upstream_trees = True

    try:
        if args.mode in ("auto", "api"):
            print(f"探測官方 API：{API_BASE}", flush=True)
            try:
                probe = fetcher.get_json(
                    f"{API_BASE}/catalog_entry?q=CBETA",
                    timeout=15,
                    attempts=1,
                )
                api_state["reachable"] = True
                api_state["probe_label"] = (
                    probe.get("label") if isinstance(probe, dict) else None
                )
                mode_used = "api"
            except Exception as error:  # noqa: BLE001 - API 不可達時改用上游
                api_state["error"] = str(error)
                print(f"官方 API 不可達，改用官方上游資料：{error}", flush=True)
                if args.mode == "api":
                    raise

        if mode_used == "api":
            used_upstream_trees = False
            print("遞迴抓取部類目錄…", flush=True)
            category_tree = crawl_api_catalog(
                fetcher, "CBETA", "部類目錄", args.cache_dir
            )
            print("遞迴抓取冊別目錄…", flush=True)
            volume_tree = crawl_api_catalog(
                fetcher, "orig", "原書目錄", args.cache_dir
            )
            print("抓取作譯者清單…", flush=True)
            api_creator_list = fetcher.get_json(
                f"{API_BASE}/download/all-creators-with-alias.json",
                cache_path=args.cache_dir / "api" / "all-creators-with-alias.json",
            )
            if not isinstance(api_creator_list, dict):
                raise CrawlError("all-creators-with-alias.json 格式錯誤")
            print("抓取年代與作品…", flush=True)
            api_dynasties = fetch_api_dynasties(fetcher, args.cache_dir)

        works, import_order, work_sources = load_authority_works(
            fetcher, args.cache_dir, warnings
        )
        if not works:
            raise CrawlError("沒有任何作品資料，無法建立目錄")

        people: dict[str, dict[str, object]] = {}
        person_xml_complete = False
        builder = UpstreamBuilder(works, warnings)
        if used_upstream_trees:
            catalog_sources = configure_sources(fetcher, args.cache_dir)
            person_xml = args.person_xml or (
                args.cache_dir / "raw" / "Buddhist_Studies_Person_Authority.xml"
            )
            if person_xml.exists():
                tail = person_xml.read_bytes()[-4096:]
                person_xml_complete = b"</TEI>" in tail
            if person_xml.exists() and not person_xml_complete:
                warnings.append(
                    "person authority XML 尚未下載完整；為避免只出現部分別名，"
                    "本次作譯者別名留空（名單與分組仍依 contributors 建立）"
                )
            else:
                people = parse_person_authority(person_xml, warnings)

            category_tree = builder.build(
                catalog_sources["bulei"], "CBETA", "部類目錄", "CBETA"
            )
            volume_tree = builder.build(
                catalog_sources["advance_nav"], "orig", "原書目錄", "orig"
            )

        if api_creators is None:
            if api_creator_list is not None:
                api_creators = build_creators_from_api(
                    api_creator_list, works, import_order
                )
            else:
                api_creators = build_creators(works, people, import_order)
        if api_dynasties is None:
            dynasty_order = fetcher.get_text(
                f"{CBETA_API_BASE}/data-static/dynasty-order.csv",
                cache_path=args.cache_dir / "authority" / "dynasty-order.csv",
            )
            api_dynasties = build_dynasties(works, dynasty_order, warnings)

        works_payload = {
            work_id: {
                **work.to_hash(label=f"{work.n} {work.title}"),
                "juans": list(range(1, work.juans + 1)),
            }
            for work_id, work in sorted(works.items())
        }
        work_files_payload = {
            work_id: work.file for work_id, work in sorted(works.items())
        }

        catalog_payload = {
            "source": "CBETA Online mobile catalog API semantics",
            "category": category_tree,
            "volume": volume_tree,
        }
        creators_payload = api_creators
        dynasties_payload = {"dynasties": api_dynasties}

        category_counts = flatten_catalog_refs(category_tree)
        volume_counts = flatten_catalog_refs(volume_tree)
        if used_upstream_trees:
            unused = sorted(set(works) - builder.used_work_ids)
            if unused:
                warnings.append(
                    f"{len(unused)} 部作品未出現在部類/冊別目錄（API Work 表仍會列入作譯者/年代）："
                    + "、".join(unused[:20])
                )
        else:
            referenced = catalog_work_ids(category_tree) | catalog_work_ids(
                volume_tree
            )
            missing = sorted(referenced - set(works))
            if missing:
                warnings.append(
                    f"目錄引用了 {len(missing)} 部在 Authority-Databases 找不到的作品："
                    + "、".join(missing[:20])
                )
            catalog_creators = {
                str(item.get("id"))
                for work in works.values()
                for item in work.contributors
                if item.get("id")
            }
            api_creator_ids = set(
                api_creator_list if api_creator_list is not None else {}
            )
            missing_creators = sorted(catalog_creators - api_creator_ids)
            if missing_creators:
                warnings.append(
                    f"{len(missing_creators)} 位作譯者不在 API 作譯者清單："
                    + "、".join(missing_creators[:20])
                )

        if used_upstream_trees:
            catalog_source_entries = [
                {
                    "name": "cbwork-bin/bulei/bulei.txt",
                    "url": f"{CBWORK_BASE}/bulei/bulei.txt",
                },
                {
                    "name": "cbwork-bin/nav/advance_nav.txt",
                    "url": f"{CBWORK_BASE}/nav/advance_nav.txt",
                },
                {
                    "name": "Authority-Databases/person",
                    "url": f"{AUTHORITY_BASE}/authority_person/Buddhist_Studies_Person_Authority.xml",
                    "complete": person_xml_complete,
                    "people": len(people),
                },
                {
                    "name": "cbeta-api/dynasty-order.csv",
                    "url": f"{CBETA_API_BASE}/data-static/dynasty-order.csv",
                },
            ]
        else:
            catalog_source_entries = [
                {
                    "name": "catalog_entry",
                    "url": f"{API_BASE}/catalog_entry?q=CBETA",
                    "nodes": count_catalog_nodes(category_tree),
                },
                {
                    "name": "catalog_entry",
                    "url": f"{API_BASE}/catalog_entry?q=orig",
                    "nodes": count_catalog_nodes(volume_tree),
                },
                {
                    "name": "all-creators-with-alias.json",
                    "url": f"{API_BASE}/download/all-creators-with-alias.json",
                    "creators": len(api_creator_list or {}),
                },
                {
                    "name": "dynasty-all.csv + works",
                    "url": f"{API_BASE}/download/stat/dynasty-all.csv",
                    "dynasties": len(api_dynasties),
                },
            ]

        manifest = {
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "generator": "tool/crawl_cbeta_catalog.py",
            "mode": mode_used,
            "mobile_page": MOBILE_PAGE,
            "api": api_state,
            "rate_limit": {
                "serial": True,
                "min_interval_seconds": args.min_interval,
                "max_per_minute": args.max_per_minute,
                "max_per_second": args.max_per_second,
            },
            "sources": work_sources + catalog_source_entries,
            "counts": {
                "works": len(works),
                "creators": len(creators_payload.get("creators", {})),
                "dynasties": len(api_dynasties),
                "category_categories": category_counts[0],
                "category_works": category_counts[1],
                "category_html": category_counts[2],
                "volume_categories": volume_counts[0],
                "volume_works": volume_counts[1],
                "volume_html": volume_counts[2],
            },
            "warnings": warnings,
        }

        for filename, payload in (
            ("catalog.json", catalog_payload),
            ("creators.json", creators_payload),
            ("dynasties.json", dynasties_payload),
            ("works.json", works_payload),
            ("work_files.json", work_files_payload),
            ("manifest.json", manifest),
        ):
            path = args.output / filename
            with path.open("w", encoding="utf-8") as handle:
                json.dump(payload, handle, ensure_ascii=False, separators=(",", ":"))
                handle.write("\n")
            print(f"寫入 {path}（{path.stat().st_size} bytes）", flush=True)

        print(
            "完成："
            f"部類 {category_counts[1]} 部、冊別 {volume_counts[1]} 部、"
            f"作譯者 {len(creators_payload.get('creators', {}))} 人、"
            f"年代 {len(api_dynasties)} 個、作品 {len(works)} 部",
            flush=True,
        )
        return 0
    finally:
        fetcher.close()


if __name__ == "__main__":
    sys.exit(main())
