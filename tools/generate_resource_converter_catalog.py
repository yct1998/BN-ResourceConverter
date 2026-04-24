from __future__ import annotations

import json
import re
from collections import defaultdict
from copy import deepcopy
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

BUYABLE_TYPES = {
    "AMMO",
    "ARMOR",
    "BANDOLIER",
    "BIONIC_ITEM",
    "BOOK",
    "COMESTIBLE",
    "CONTAINER",
    "ENGINE",
    "GENERIC",
    "GUN",
    "GUNMOD",
    "MAGAZINE",
    "MAGAZINE_WELL",
    "PET_ARMOR",
    "TOOL",
    "TOOLMOD",
    "TOOL_ARMOR",
    "WHEEL",
}

CATEGORY_INFO = {
    "weapons_ranged": {
        "name": "枪械与远程",
        "desc": "枪械、弓弩与其他远程武器。",
    },
    "weapons_misc": {
        "name": "近战与武器杂项",
        "desc": "近战武器、武器平台与战斗杂项。",
    },
    "ammo": {
        "name": "弹药",
        "desc": "子弹、电池、燃料弹药与可堆叠弹药。",
    },
    "magazines": {
        "name": "弹匣与供弹",
        "desc": "弹匣、供弹机构与相关附件。",
    },
    "armor": {
        "name": "护甲与穿戴",
        "desc": "护具、服装、携行穿戴与宠物护甲。",
    },
    "containers": {
        "name": "容器",
        "desc": "瓶、桶、袋、壶与其他可装载物品。",
    },
    "tools": {
        "name": "工具与电子",
        "desc": "常规工具、电子设备与可激活装置。",
    },
    "consumables": {
        "name": "食物与药品",
        "desc": "食物、饮料、药品和一般消耗品。",
    },
    "books": {
        "name": "书籍与资料",
        "desc": "配方书、技能书与其他读物。",
    },
    "materials": {
        "name": "材料与零件",
        "desc": "原料、燃料、制造材料与通用零件。",
    },
    "vehicle_parts": {
        "name": "车辆部件",
        "desc": "车辆零件、发动机、轮组与车载结构件。",
    },
    "bionics": {
        "name": "仿生与高科技",
        "desc": "仿生安装物与高级技术物资。",
    },
    "misc": {
        "name": "其他杂项",
        "desc": "其余可购买、可回收但不适合归入上列分类的物品。",
    },
}

REGISTRY: dict[str, dict] = {}
MERGED_CACHE: dict[str, dict] = {}
PRICE_CACHE: dict[tuple[str, str], int] = {}


@dataclass(frozen=True)
class Translatable:
    text: str


def tr(text: str) -> Translatable | str:
    text = text or ""
    return Translatable(text) if text else ""


# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------
def find_game_items_root(start: Path) -> Path:
    for base in [start] + list(start.parents):
        candidate = base / "bn" / "game0" / "data" / "json" / "items"
        if candidate.exists():
            return candidate
    raise FileNotFoundError("Could not locate bn/game0/data/json/items from script location")


SCRIPT_PATH = Path(__file__).resolve()
MOD_DIR = SCRIPT_PATH.parent.parent
GAME_ITEMS_DIR = find_game_items_root(SCRIPT_PATH.parent)
CATALOG_META_FILE = MOD_DIR / "generated_catalog.lua"
CATALOG_CATEGORY_ITEMS_FILE = MOD_DIR / "generated_catalog_category_items.lua"
CATALOG_ITEMS_FILE = MOD_DIR / "generated_catalog_items.lua"


# ---------------------------------------------------------------------------
# JSON cleanup / loading
# ---------------------------------------------------------------------------
def strip_json_comments(text: str) -> str:
    out: list[str] = []
    in_string = False
    escape = False
    i = 0
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""

        if in_string:
            out.append(ch)
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            i += 1
            continue

        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue

        if ch == "/" and nxt == "/":
            i += 2
            while i < len(text) and text[i] not in "\r\n":
                i += 1
            continue

        if ch == "/" and nxt == "*":
            i += 2
            while i + 1 < len(text) and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            i += 2
            continue

        out.append(ch)
        i += 1

    return "".join(out)


def strip_trailing_commas(text: str) -> str:
    out: list[str] = []
    in_string = False
    escape = False
    i = 0
    while i < len(text):
        ch = text[i]

        if in_string:
            out.append(ch)
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            i += 1
            continue

        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue

        if ch == ",":
            j = i + 1
            while j < len(text) and text[j].isspace():
                j += 1
            if j < len(text) and text[j] in "]}":
                i += 1
                continue

        out.append(ch)
        i += 1

    return "".join(out)


def load_json_objects(path: Path) -> list[dict]:
    raw = path.read_text(encoding="utf-8")
    cleaned = strip_trailing_commas(strip_json_comments(raw))
    try:
        data = json.loads(cleaned)
    except json.JSONDecodeError as exc:
        print(f"[WARN] Skipping {path}: {exc}")
        return []

    if isinstance(data, dict):
        return [data]
    if isinstance(data, list):
        return [obj for obj in data if isinstance(obj, dict)]
    return []


# ---------------------------------------------------------------------------
# Money parsing
# ---------------------------------------------------------------------------
def parse_money_to_cents(value) -> int:
    if value is None:
        return 0
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, (int, float)):
        return int(round(float(value)))

    text = str(value).strip()
    if not text:
        return 0

    total = 0.0
    for number, unit in re.findall(r"([0-9]+(?:\.[0-9]+)?)\s*([A-Za-z]+)", text):
        amount = float(number)
        unit_l = unit.lower()
        if unit_l == "cent":
            total += amount
        elif unit_l == "usd":
            total += amount * 100
        elif unit_l == "kusd":
            total += amount * 100_000
        elif unit_l == "musd":
            total += amount * 100_000_000

    if total > 0:
        return int(round(total))

    if re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", text):
        return int(round(float(text)))

    return 0


# ---------------------------------------------------------------------------
# Registry / inheritance
# ---------------------------------------------------------------------------
def is_buyable_type_name(type_name: str) -> bool:
    return text_to_string(type_name) in BUYABLE_TYPES


def is_zero_price_material_ammo_candidate(resolved: dict) -> bool:
    item_type = text_to_string(resolved.get("type"))
    category = text_to_string(resolved.get("category")).lower()
    return item_type == "AMMO" and category.startswith("scrap_")


def should_replace_registry_entry(existing: dict, candidate: dict) -> bool:
    existing_type = existing.get("type")
    candidate_type = candidate.get("type")

    existing_buyable = is_buyable_type_name(existing_type)
    candidate_buyable = is_buyable_type_name(candidate_type)
    if existing_buyable != candidate_buyable:
        return candidate_buyable

    return True


def build_registry() -> None:
    REGISTRY.clear()
    MERGED_CACHE.clear()
    PRICE_CACHE.clear()

    for path in sorted(GAME_ITEMS_DIR.rglob("*.json")):
        lowered = path.as_posix().lower()
        if "/obsoletion/" in lowered or "/obsolete/" in lowered or "/tests/" in lowered:
            continue
        for obj in load_json_objects(path):
            key = obj.get("id") or obj.get("abstract")
            if not key:
                continue
            key = str(key)
            existing = REGISTRY.get(key)
            if existing and not should_replace_registry_entry(existing["data"], obj):
                continue
            REGISTRY[key] = {"data": obj, "path": path}


def resolve_entry(key: str, stack: set[str] | None = None) -> dict:
    if key in MERGED_CACHE:
        return deepcopy(MERGED_CACHE[key])

    if key not in REGISTRY:
        return {}

    stack = stack or set()
    if key in stack:
        return {}
    stack.add(key)

    raw = REGISTRY[key]["data"]
    parent_key = raw.get("copy-from")
    merged: dict = {}

    if isinstance(parent_key, str) and parent_key in REGISTRY:
        merged = resolve_entry(parent_key, stack)

    parent_flags = list(merged.get("flags", [])) if isinstance(merged.get("flags"), list) else []

    for field in (
        "id",
        "type",
        "name",
        "description",
        "category",
        "volume",
        "weight",
        "stackable",
        "count",
        "charges",
        "initial_charges",
        "max_charges",
        "ammo_type",
    ):
        if field in raw:
            merged[field] = deepcopy(raw[field])

    if isinstance(raw.get("flags"), list):
        for flag in raw["flags"]:
            if flag not in parent_flags:
                parent_flags.append(flag)

    extend = raw.get("extend")
    if isinstance(extend, dict) and isinstance(extend.get("flags"), list):
        for flag in extend["flags"]:
            if flag not in parent_flags:
                parent_flags.append(flag)

    delete = raw.get("delete")
    if isinstance(delete, dict) and isinstance(delete.get("flags"), list):
        parent_flags = [flag for flag in parent_flags if flag not in delete["flags"]]

    if parent_flags:
        merged["flags"] = parent_flags
    else:
        merged.pop("flags", None)

    merged["_path"] = REGISTRY[key]["path"].relative_to(GAME_ITEMS_DIR).as_posix()
    merged["_copy_from"] = parent_key if isinstance(parent_key, str) and parent_key in REGISTRY else None

    MERGED_CACHE[key] = deepcopy(merged)
    return deepcopy(merged)


def resolve_price(key: str, field: str = "price", stack: set[tuple[str, str]] | None = None) -> int:
    cache_key = (key, field)
    if cache_key in PRICE_CACHE:
        return PRICE_CACHE[cache_key]

    if key not in REGISTRY:
        return 0

    stack = stack or set()
    if cache_key in stack:
        return 0
    stack.add(cache_key)

    raw = REGISTRY[key]["data"]
    parent_key = raw.get("copy-from")
    value = 0

    if isinstance(parent_key, str) and parent_key in REGISTRY:
        value = resolve_price(parent_key, field, stack)

    if field in raw:
        value = parse_money_to_cents(raw[field])

    relative = raw.get("relative")
    if isinstance(relative, dict) and field in relative:
        value += parse_money_to_cents(relative[field])

    proportional = raw.get("proportional")
    if isinstance(proportional, dict) and field in proportional:
        try:
            value = int(round(value * float(proportional[field])))
        except (TypeError, ValueError):
            pass

    value = max(value, 0)
    PRICE_CACHE[cache_key] = value
    return value


# ---------------------------------------------------------------------------
# Normalization / categorization
# ---------------------------------------------------------------------------
def name_to_string(value) -> str:
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, dict):
        for key in ("str", "str_sp", "str_pl"):
            field = value.get(key)
            if isinstance(field, str) and field.strip():
                return field.strip()
        for field in value.values():
            if isinstance(field, str) and field.strip():
                return field.strip()
    return ""


def text_to_string(value) -> str:
    if isinstance(value, str):
        return value.strip()
    if value is None:
        return ""
    return str(value).strip()


def is_stackable_item(resolved: dict) -> bool:
    return bool(resolved.get("stackable")) or resolved.get("type") == "AMMO"


def is_charge_based_item(resolved: dict) -> bool:
    return text_to_string(resolved.get("type")) == "AMMO"


def default_units(resolved: dict) -> int:
    if isinstance(resolved.get("count"), int) and resolved["count"] > 0:
        return int(resolved["count"])
    if is_charge_based_item(resolved):
        for field in ("charges", "initial_charges", "max_charges"):
            if isinstance(resolved.get(field), int) and resolved[field] > 0:
                return int(resolved[field])
    return 1


def spawn_charges(resolved: dict) -> int:
    if is_charge_based_item(resolved):
        return max(0, default_units(resolved))
    for field in ("charges", "initial_charges"):
        if isinstance(resolved.get(field), int) and resolved[field] >= 0:
            return int(resolved[field])
    return 0


def classify_item(resolved: dict) -> str:
    item_type = text_to_string(resolved.get("type"))
    category = text_to_string(resolved.get("category")).lower()
    path = text_to_string(resolved.get("_path")).lower()

    if "/vehicle/" in path or category == "veh_parts":
        return "vehicle_parts"

    if item_type in {"GUN", "GUNMOD"}:
        return "weapons_ranged"

    if item_type == "AMMO":
        return "ammo"

    if item_type in {"MAGAZINE", "MAGAZINE_WELL"}:
        return "magazines"

    if item_type in {"ARMOR", "TOOL_ARMOR", "PET_ARMOR", "BANDOLIER"}:
        return "armor"

    if item_type == "CONTAINER":
        return "containers"

    if item_type in {"TOOL", "TOOLMOD"}:
        return "tools"

    if item_type == "COMESTIBLE":
        return "consumables"

    if item_type == "BOOK":
        return "books"

    if item_type == "BIONIC_ITEM":
        return "bionics"

    if item_type in {"ENGINE", "WHEEL"}:
        return "vehicle_parts"

    if any(token in path for token in ("/resources/", "/fuel", "/materials/")):
        return "materials"

    if category in {
        "components",
        "spare_parts",
        "scrap_electronics",
        "scrap_metal",
        "guns_parts",
        "veh_parts",
        "tool_parts",
    }:
        return "materials"

    if any(token in path for token in ("/melee/", "/weapons/", "/weapon/", "/martial/", "/archery/")):
        return "weapons_misc"

    return "misc"


def is_buyable(key: str, resolved: dict) -> bool:
    if text_to_string(resolved.get("type")) not in BUYABLE_TYPES:
        return False

    path = text_to_string(resolved.get("_path")).lower()
    flags = set(resolved.get("flags", [])) if isinstance(resolved.get("flags"), list) else set()

    if any(token in path for token in ("fake.json", "/obsolete/", "/obsoletion/", "/tests/")):
        return False

    if key.startswith("fake_") or key.startswith("debug_") or key.startswith("test_"):
        return False

    if "PSEUDO" in flags:
        return False

    if resolve_price(key, "price") <= 0 and not is_zero_price_material_ammo_candidate(resolved):
        return False

    return True


# ---------------------------------------------------------------------------
# Lua serialization
# ---------------------------------------------------------------------------
def lua_escape(text: str) -> str:
    return (
        text.replace("\\", "\\\\")
        .replace("\r", "\\r")
        .replace("\n", "\\n")
        .replace('"', '\\"')
    )


def to_lua(value, indent: int = 0) -> str:
    spacer = " " * indent

    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(int(value) if isinstance(value, int) else value)
    if isinstance(value, Translatable):
        return f'locale.gettext("{lua_escape(value.text)}")'
    if isinstance(value, str):
        return f'"{lua_escape(value)}"'
    if isinstance(value, list):
        if not value:
            return "{}"
        lines = ["{"]
        for item in value:
            lines.append(" " * (indent + 2) + to_lua(item, indent + 2) + ",")
        lines.append(spacer + "}")
        return "\n".join(lines)
    if isinstance(value, dict):
        if not value:
            return "{}"
        lines = ["{"]
        for key in sorted(value.keys()):
            if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", str(key)):
                lua_key = str(key)
            else:
                lua_key = f"[{to_lua(str(key), indent + 2)}]"
            lines.append(" " * (indent + 2) + f"{lua_key} = {to_lua(value[key], indent + 2)},")
        lines.append(spacer + "}")
        return "\n".join(lines)
    raise TypeError(f"Unsupported type for Lua serialization: {type(value)!r}")


# ---------------------------------------------------------------------------
# Catalog builder
# ---------------------------------------------------------------------------
def build_catalog() -> tuple[dict, dict, dict]:
    items: dict[str, dict] = {}
    category_items: dict[str, list[str]] = defaultdict(list)

    for key in sorted(REGISTRY.keys()):
        resolved = resolve_entry(key)
        if not resolved or "id" not in resolved:
            continue
        if not is_buyable(key, resolved):
            continue

        base_price = resolve_price(key, "price")
        postapoc_price = resolve_price(key, "price_postapoc")
        if base_price <= 0 and is_zero_price_material_ammo_candidate(resolved):
            base_price = 1
        if postapoc_price <= 0 and is_zero_price_material_ammo_candidate(resolved):
            postapoc_price = 1
        category_id = classify_item(resolved)
        item_name = name_to_string(resolved.get("name")) or key
        item_desc = text_to_string(resolved.get("description"))

        items[key] = {
            "id": key,
            "name": tr(item_name),
            "description": tr(item_desc),
            "type": text_to_string(resolved.get("type")),
            "category": category_id,
            "price": base_price,
            "price_postapoc": postapoc_price,
            "weight": text_to_string(resolved.get("weight")),
            "volume": text_to_string(resolved.get("volume")),
            "default_units": max(1, default_units(resolved)),
            "charge_based": is_charge_based_item(resolved),
            "spawn_charges": max(0, spawn_charges(resolved)),
            "stackable": is_stackable_item(resolved),
            "source": text_to_string(resolved.get("_path")),
            "copy_from": text_to_string(resolved.get("_copy_from")),
        }
        category_items[category_id].append(key)

    for category_id, item_ids in category_items.items():
        item_ids.sort(
            key=lambda item_id: (
                (items[item_id]["name"].text if isinstance(items[item_id]["name"], Translatable) else str(items[item_id]["name"])).lower(),
                item_id,
            )
        )

    categories = []
    for category_id, info in CATEGORY_INFO.items():
        item_ids = category_items.get(category_id, [])
        if not item_ids:
            continue
        categories.append(
            {
                "id": category_id,
                "name": tr(info["name"]),
                "desc": tr(info["desc"]),
                "count": len(item_ids),
            }
        )

    meta = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "source_root": GAME_ITEMS_DIR.as_posix(),
        "categories": categories,
    }
    category_item_index = dict(category_items)

    return meta, category_item_index, items


def write_catalog_meta(meta: dict) -> None:
    header = (
        "-- Generated by tools/generate_resource_converter_catalog.py\n"
        "-- Source: bn/game0/data/json/items\n"
        "-- Metadata only. Category index is stored in generated_catalog_category_items.lua and item records in generated_catalog_items.lua\n"
        "-- Do not edit this file by hand. Regenerate it with the script.\n\n"
    )
    lua_text = header + "return " + to_lua(meta, 0) + "\n"
    CATALOG_META_FILE.write_text(lua_text, encoding="utf-8", newline="\n")


def write_catalog_category_items(category_items: dict) -> None:
    header = (
        "-- Generated by tools/generate_resource_converter_catalog.py\n"
        "-- Source: bn/game0/data/json/items\n"
        "-- Category index only. Item records are stored in generated_catalog_items.lua\n"
        "-- Do not edit this file by hand. Regenerate it with the script.\n\n"
    )
    lua_text = header + "return " + to_lua(category_items, 0) + "\n"
    CATALOG_CATEGORY_ITEMS_FILE.write_text(lua_text, encoding="utf-8", newline="\n")


def write_catalog_items(items: dict) -> None:
    header = (
        "-- Generated by tools/generate_resource_converter_catalog.py\n"
        "-- Source: bn/game0/data/json/items\n"
        "-- Strings are wrapped with locale.gettext for lang extraction.\n"
        "-- Do not edit this file by hand. Regenerate it with the script.\n\n"
    )
    lua_text = header + "return " + to_lua(items, 0) + "\n"
    CATALOG_ITEMS_FILE.write_text(lua_text, encoding="utf-8", newline="\n")


def main() -> None:
    build_registry()
    meta, category_items, items = build_catalog()
    write_catalog_meta(meta)
    write_catalog_category_items(category_items)
    write_catalog_items(items)

    total_items = len(items)
    total_categories = len(meta["categories"])
    print(f"Generated {total_items} buyable items across {total_categories} categories")
    print(f"Wrote catalog meta to: {CATALOG_META_FILE}")
    print(f"Wrote category index to: {CATALOG_CATEGORY_ITEMS_FILE}")
    print(f"Wrote catalog items to: {CATALOG_ITEMS_FILE}")


if __name__ == "__main__":
    main()
