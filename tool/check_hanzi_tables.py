#!/usr/bin/env python3
"""检查简繁词表的候选顺序与双向覆盖情况。

用法：
    python3 tool/check_hanzi_tables.py
    python3 tool/check_hanzi_tables.py --strict

默认只有结构性错误（文件缺失、JSON 形状错误、候选为空/重复）会导致失败。
以下三类只作为提示列出，因为它们是词表长期存在的编写约定，未必是错误：

* 原字在候选中但不是第一项：例如「厂」写作 ["廠", "厂"]，表示标准繁体优先、
  原字作为兜底；而「云」写作 ["云", "雲"]，表示云是繁体也通用的共用字。
* 双向成员不完全对称：异体字（如 藴/蘊、衆/眾）通常只在一侧出现。
* 首选往返不是原字：异体字或分工不同的字（如 乾/干）会自然出现。

加 --strict 时，以上提示也会导致非零退出码，便于在清理词表时逐项确认。
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TABLES = {
    "simplified_to_traditional": ROOT / "assets/hanzi_simplified_to_traditional.json",
    "traditional_to_simplified": ROOT / "assets/hanzi_traditional_to_simplified.json",
    "phrases_simplified_to_traditional": ROOT / "assets/phrases_simplified_to_traditional.json",
    "phrases_traditional_to_simplified": ROOT / "assets/phrases_traditional_to_simplified.json",
}


def load(path: Path) -> dict[str, list[str]]:
    with path.open(encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError("顶层必须是 JSON 对象")
    return data


def validate_shape(name: str, data: dict) -> list[str]:
    errors: list[str] = []
    for key, value in data.items():
        if not isinstance(key, str) or not key:
            errors.append(f"{name}: 非法 key {key!r}")
            continue
        if isinstance(value, str):
            errors.append(f"{name}: {key!r} 的值仍是字符串，不是候选数组")
            continue
        if not isinstance(value, list) or not value:
            errors.append(f"{name}: {key!r} 的候选必须是非空数组")
            continue
        seen: set[str] = set()
        for candidate in value:
            if not isinstance(candidate, str) or not candidate:
                errors.append(f"{name}: {key!r} 含非法候选 {candidate!r}")
            elif candidate in seen:
                errors.append(f"{name}: {key!r} 的候选重复 {candidate!r}")
            else:
                seen.add(candidate)
    return errors


def reverse_membership_warnings(
    name: str,
    data: dict[str, list[str]],
    other_name: str,
    other: dict[str, list[str]],
) -> list[str]:
    warnings: list[str] = []
    for key, candidates in data.items():
        for candidate in candidates:
            if candidate not in other:
                continue
            if key not in other[candidate]:
                warnings.append(
                    f"{name}: {key!r} -> {candidate!r}，"
                    f"但 {other_name}[{candidate!r}]={other[candidate]!r} 不含 {key!r}"
                )
    return warnings


def first_round_trip_warnings(
    name: str,
    data: dict[str, list[str]],
    other_name: str,
    other: dict[str, list[str]],
) -> list[str]:
    warnings: list[str] = []
    for key, candidates in data.items():
        first = candidates[0]
        if first not in other:
            continue
        back = other[first]
        if not back or back[0] != key:
            warnings.append(
                f"{name}: {key!r} 首选 {first!r}，"
                f"但 {other_name}[{first!r}] 首选是 {back[0] if back else None!r}"
            )
    return warnings


def order_groups(data: dict[str, list[str]]) -> tuple[list[tuple], list[tuple], list[tuple]]:
    self_first = []
    self_later = []
    self_absent = []
    for key, candidates in data.items():
        if candidates and candidates[0] == key:
            self_first.append((key, candidates))
        elif key in candidates:
            self_later.append((key, candidates))
        else:
            self_absent.append((key, candidates))
    return self_first, self_later, self_absent


def print_group(title: str, rows: list[tuple], limit: int = 200) -> None:
    print(f"\n{title}（{len(rows)}）")
    for key, candidates in rows[:limit]:
        print(f"  {key}: {candidates}")
    if len(rows) > limit:
        print(f"  ... 其余 {len(rows) - limit} 项省略")


def print_warnings(title: str, warnings: list[str], limit: int = 60) -> None:
    print(f"\n{title}（{len(warnings)}）")
    for warning in warnings[:limit]:
        print(f"  {warning}")
    if len(warnings) > limit:
        print(f"  ... 其余 {len(warnings) - limit} 项省略")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--strict",
        action="store_true",
        help="把顺序、双向覆盖与往返提示也视为错误",
    )
    args = parser.parse_args()

    tables: dict[str, dict[str, list[str]]] = {}
    structural_errors: list[str] = []
    for name, path in TABLES.items():
        if not path.exists():
            structural_errors.append(f"{name}: 文件不存在 {path}")
            continue
        try:
            data = load(path)
        except (OSError, ValueError, json.JSONDecodeError) as error:
            structural_errors.append(f"{name}: 读取失败 {error}")
            continue
        tables[name] = data
        structural_errors.extend(validate_shape(name, data))

    consistency_warnings: list[str] = []
    round_trip_warnings: list[str] = []
    s2t = tables.get("simplified_to_traditional", {})
    t2s = tables.get("traditional_to_simplified", {})
    ps2t = tables.get("phrases_simplified_to_traditional", {})
    pt2s = tables.get("phrases_traditional_to_simplified", {})

    if s2t and t2s:
        consistency_warnings.extend(
            reverse_membership_warnings("简→繁", s2t, "繁→简", t2s)
        )
        consistency_warnings.extend(
            reverse_membership_warnings("繁→简", t2s, "简→繁", s2t)
        )
        round_trip_warnings.extend(
            first_round_trip_warnings("简→繁", s2t, "繁→简", t2s)
        )
        round_trip_warnings.extend(
            first_round_trip_warnings("繁→简", t2s, "简→繁", s2t)
        )
    if ps2t and pt2s:
        consistency_warnings.extend(
            reverse_membership_warnings("简→繁词组", ps2t, "繁→简词组", pt2s)
        )
        consistency_warnings.extend(
            reverse_membership_warnings("繁→简词组", pt2s, "简→繁词组", ps2t)
        )

    print("词表检查")
    for name, data in tables.items():
        self_first, self_later, self_absent = order_groups(data)
        print(
            f"\n{name}: {len(data)} 项"
            f"（原字第一 {len(self_first)}，"
            f"原字在后 {len(self_later)}，"
            f"原字缺席 {len(self_absent)}）"
        )

    _, s2t_later, _ = order_groups(s2t)
    _, t2s_later, _ = order_groups(t2s)
    print_group("简→繁：原字在候选中但不是第一项（需人工确认）", s2t_later)
    print_group("繁→简：原字在候选中但不是第一项（需人工确认）", t2s_later)

    if structural_errors:
        print(f"\n结构性错误（{len(structural_errors)}）")
        for error in structural_errors:
            print(f"  {error}")

    if consistency_warnings:
        print_warnings(
            "双向成员覆盖提示（多为异体字）",
            consistency_warnings,
        )

    if round_trip_warnings:
        print_warnings(
            "首选往返提示（多为异体字或分工不同的字）",
            round_trip_warnings,
        )

    order_count = len(s2t_later) + len(t2s_later)
    warning_count = (
        order_count + len(consistency_warnings) + len(round_trip_warnings)
    )
    failed = bool(structural_errors) or (args.strict and warning_count > 0)

    print("\n结论")
    if structural_errors:
        print("  发现结构性错误，请按上方清单处理。")
        return 1
    if args.strict and warning_count > 0:
        print(f"  --strict：发现 {warning_count} 项提示，请逐项确认。")
        return 1
    print("  未发现结构性错误。")
    if warning_count > 0:
        print(
            f"  顺序疑点 {order_count} 项；双向覆盖提示 "
            f"{len(consistency_warnings)} 项；首选往返提示 "
            f"{len(round_trip_warnings)} 项。"
        )
        print("  厂/云等顺序差异属于编写约定，需要时用 --strict 复查。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
