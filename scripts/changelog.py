#!/usr/bin/env python3
"""Changelog fragments and release sections of the ecosystem changelog
contract, version 1. Every operation validates all fragments before it
writes anything.

Rules, markers, output bytes and exit codes follow the reference
implementation in pohunekd/pohunek-companion (crates/changelog).

usage: changelog check
       changelog fold <version> [--surface <name>] [--date YYYY-MM-DD]
       changelog notes <version> [--surface <name>]

Reads changelog.toml and changelog.d/ from the current directory; scripts/changelog
runs it from the repository root.
"""

import datetime
import re
import sys
import tomllib
from pathlib import Path

CONFIG_FILE = "changelog.toml"
FRAGMENT_DIR = "changelog.d"
START_MARKER = "<!-- pohunek-changelog:start -->"
END_MARKER = "<!-- pohunek-changelog:end -->"

DELIMITER = "---"
NO_CHANGES = "No user-facing changes."
SURFACE_SEPARATOR = ", "
CHANGELOG_TITLE = "# Changelog"
U64_MAX = 2**64 - 1

USAGE = """usage:
  changelog check
  changelog fold <version> [--surface <name>] [--date YYYY-MM-DD]
  changelog notes <version> [--surface <name>]"""

# Section order inside a version: (key in a fragment header, heading).
KINDS = (
    ("added", "Added"),
    ("changed", "Changed"),
    ("deprecated", "Deprecated"),
    ("removed", "Removed"),
    ("fixed", "Fixed"),
    ("security", "Security"),
)
KIND_KEYS = tuple(key for key, _ in KINDS)

# Characters Rust's str::trim removes (Unicode White_Space). Python's own
# str.strip also removes U+001C..U+001F, which the contract does not.
WHITESPACE = (
    "\t\n\x0b\x0c\r \x85\xa0\u1680\u2000\u2001\u2002\u2003\u2004\u2005"
    "\u2006\u2007\u2008\u2009\u200a\u2028\u2029\u202f\u205f\u3000"
)


class ChangelogError(Exception):
    """Failure of the tool; `usage` marks a bad command line (exit code 2)."""

    def __init__(self, message, usage=False):
        super().__init__(message)
        self.usage = usage


class ConfigError(ChangelogError):
    pass


class ArgumentError(ChangelogError):
    pass


def trim(value):
    return value.strip(WHITESPACE)


def is_blank(value):
    return trim(value) == ""


def split_lines(text):
    """Lines as Rust's str::lines: split on LF, one trailing CR removed."""
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return [line[:-1] if line.endswith("\r") else line for line in lines]


def split_inclusive(text):
    """Lines of `text` with their line feeds; the last may have none."""
    lines = text.split("\n")
    out = [line + "\n" for line in lines[:-1]]
    if lines[-1] != "":
        out.append(lines[-1])
    return out


def read_text(path):
    try:
        with open(path, "rb") as handle:
            return handle.read().decode("utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise ChangelogError(f"{path}: {error}") from error


def write_text(path, text):
    try:
        with open(path, "wb") as handle:
            handle.write(text.encode("utf-8"))
    except OSError as error:
        raise ChangelogError(f"{path}: {error}") from error


def remove_file(path):
    try:
        Path(path).unlink()
    except OSError as error:
        raise ChangelogError(f"{path}: {error}") from error


def is_ascii_lower(value):
    return all("a" <= char <= "z" for char in value)


def valid_slug(value):
    """Lowercase ASCII words and digits joined by single hyphens."""
    return value != "" and all(
        word != "" and all("a" <= c <= "z" or "0" <= c <= "9" for c in word)
        for word in value.split("-")
    )


def valid_repository(value):
    def valid_part(part):
        return part != "" and all(
            c.isascii() and (c.isalnum() or c in "-_.") for c in part
        )

    owner, separator, name = value.partition("/")
    return separator == "/" and valid_part(owner) and valid_part(name)


class Config:
    """Repository layout: a single changelog file, or named surfaces."""

    def __init__(self, repository, changelog=None, surfaces=None):
        self.repository = repository
        self.changelog = changelog
        self.surfaces = surfaces

    def __eq__(self, other):
        return (
            isinstance(other, Config)
            and self.repository == other.repository
            and self.changelog == other.changelog
            and self.surfaces == other.surfaces
        )

    @classmethod
    def load(cls, path):
        try:
            with open(path, "rb") as handle:
                raw = tomllib.load(handle)
        except OSError as error:
            raise ChangelogError(f"{path}: {error}") from error
        except (tomllib.TOMLDecodeError, UnicodeDecodeError) as error:
            raise ConfigError(f"{path}: {error}") from error
        return cls.from_raw(raw, path)

    @classmethod
    def from_raw(cls, raw, path=CONFIG_FILE):
        unknown = sorted(set(raw) - {"repository", "changelog", "surfaces"})
        if unknown:
            raise ConfigError(f"{path}: unknown field `{unknown[0]}`")
        repository = raw.get("repository")
        if not isinstance(repository, str):
            raise ConfigError(f"{path}: missing string field `repository`")
        changelog = raw.get("changelog")
        surfaces = raw.get("surfaces")
        if changelog is not None and not isinstance(changelog, str):
            raise ConfigError(f"{path}: `changelog` must be a string path")
        if surfaces is not None:
            if not isinstance(surfaces, dict) or not all(
                isinstance(value, str) for value in surfaces.values()
            ):
                raise ConfigError(
                    f"{path}: `surfaces` must be a table of string paths"
                )
        if not valid_repository(repository):
            raise ConfigError(f"repository must be owner/name: {repository}")
        if changelog is not None and surfaces is None:
            return cls(repository, changelog=Path(changelog))
        if changelog is None and surfaces:
            for name in surfaces:
                if not valid_slug(name):
                    raise ConfigError(f"invalid surface name: {name}")
            return cls(
                repository,
                surfaces={name: Path(value) for name, value in surfaces.items()},
            )
        raise ConfigError("declare either changelog or a non-empty [surfaces] table")

    def changelog_path(self, surface):
        """Changelog file (relative to the root) that a command of `surface` touches."""
        if self.surfaces is None:
            if surface is not None:
                raise ArgumentError(
                    "--surface does not apply to a single-product repository"
                )
            return self.changelog
        if surface is None:
            raise ArgumentError("this repository has surfaces: pass --surface <name>")
        if surface not in self.surfaces:
            raise ArgumentError(f"unknown surface: {surface}")
        return self.surfaces[surface]

    def declared_surfaces(self):
        """Surfaces a fragment may name; None in a single-product repository."""
        return None if self.surfaces is None else sorted(self.surfaces)


class Fragment:
    def __init__(self, file_name, number, slug, kind, breaking, surfaces, text):
        self.file_name = file_name
        self.number = number
        self.slug = slug
        self.kind = kind
        self.breaking = breaking
        self.surfaces = surfaces
        self.text = text

    def belongs_to(self, surface):
        return surface is None or surface in self.surfaces


def parse_file_name(name):
    """`<N>-<slug>.md`: N has no leading zero; the slug is valid_slug."""
    if not name.endswith(".md"):
        return None
    number, separator, slug = name[: -len(".md")].partition("-")
    if separator != "-" or not re.fullmatch(r"[1-9][0-9]*", number):
        return None
    if int(number) > U64_MAX or not valid_slug(slug):
        return None
    return int(number), slug


def trim_blank_lines(lines):
    start = next((i for i, line in enumerate(lines) if not is_blank(line)), len(lines))
    end = next(
        (i + 1 for i in range(len(lines) - 1, -1, -1) if not is_blank(lines[i])),
        start,
    )
    return lines[start:end]


def parse_fragment(file_name, data, surfaces):
    """Returns a Fragment; raises ValueError with the reason when invalid."""
    parsed = parse_file_name(file_name)
    if parsed is None:
        raise ValueError("bad file name: expected <N>-<slug>.md")
    number, slug = parsed
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        raise ValueError("not valid UTF-8") from None
    if "\r" in text:
        raise ValueError("CR in the file; line endings must be LF")
    lines = text.split("\n")
    if text.endswith("\n"):
        lines.pop()
    if not lines or lines[0] != DELIMITER:
        raise ValueError("no opening ---")
    close = next((i for i in range(1, len(lines)) if lines[i] == DELIMITER), None)
    if close is None:
        raise ValueError("no closing ---")

    fields = {}
    for line in lines[1:close]:
        key, separator, value = line.partition(": ")
        if separator != ": " or key == "" or not (key.isascii() and is_ascii_lower(key)):
            raise ValueError(f"bad header line: {line}")
        if value == "" or trim(value) != value:
            raise ValueError(f"bad value for {key}: {rust_debug(value)}")
        if key not in ("kind", "breaking", "surfaces"):
            raise ValueError(f"unknown key: {key}")
        if key in fields:
            raise ValueError(f"duplicate key: {key}")
        fields[key] = value

    kind = fields.get("kind")
    if kind is None:
        raise ValueError("missing kind")
    if kind not in KIND_KEYS:
        raise ValueError(f"unknown kind: {kind}")
    breaking_value = fields.get("breaking")
    if breaking_value in (None, "false"):
        breaking = False
    elif breaking_value == "true":
        breaking = True
    else:
        raise ValueError(f"breaking must be true or false: {breaking_value}")

    surface_value = fields.get("surfaces")
    if surfaces is None:
        if surface_value is not None:
            raise ValueError("surfaces is not allowed in a single-product repository")
        fragment_surfaces = []
    else:
        if surface_value is None:
            raise ValueError("missing surfaces")
        fragment_surfaces = surface_value.split(SURFACE_SEPARATOR)
        for index, name in enumerate(fragment_surfaces):
            if name not in surfaces:
                raise ValueError(f"unknown surface: {name}")
            if name in fragment_surfaces[:index]:
                raise ValueError(f"duplicate surface: {name}")

    body = trim_blank_lines(lines[close + 1 :])
    if not body:
        raise ValueError("empty body")
    if any(is_blank(line) for line in body):
        raise ValueError("blank line in body")
    if any(line.startswith("#") for line in body):
        raise ValueError("heading line in body")

    return Fragment(
        file_name,
        number,
        slug,
        kind,
        breaking,
        fragment_surfaces,
        " ".join(trim(line) for line in body),
    )


def rust_debug(value):
    """Quoted value as Rust's {:?} prints it for the strings the header allows."""
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    escaped = escaped.replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r")
    return f'"{escaped}"'


def load_fragments(root, config):
    """Reads and validates every fragment; any invalid one fails the whole call."""
    directory = Path(root) / FRAGMENT_DIR
    try:
        # Dotfiles (such as .gitkeep) keep the empty directory in git.
        names = sorted(
            entry.name for entry in directory.iterdir() if not entry.name.startswith(".")
        )
    except FileNotFoundError:
        names = []
    except OSError as error:
        raise ChangelogError(f"{directory}: {error}") from error

    surfaces = config.declared_surfaces()
    fragments = []
    problems = []
    for name in names:
        try:
            data = (directory / name).read_bytes()
        except OSError as error:
            problems.append(f"{FRAGMENT_DIR}/{name}: {error}")
            continue
        try:
            fragments.append(parse_fragment(name, data, surfaces))
        except ValueError as reason:
            problems.append(f"{FRAGMENT_DIR}/{name}: {reason}")
    if problems:
        raise ChangelogError("\n".join(problems))
    return fragments


def validate_version(version):
    """`X.Y.Z` or `X.Y.Z-pre.N` with decimal numbers."""
    core, separator, pre = version.partition("-")
    parts = core.split(".")
    core_ok = len(parts) == 3 and all(re.fullmatch(r"[0-9]+", part) for part in parts)
    pre_ok = separator == "" or (
        pre.startswith("pre.") and re.fullmatch(r"[0-9]+", pre[len("pre.") :]) is not None
    )
    if not (core_ok and pre_ok):
        raise ArgumentError(f"version must be X.Y.Z or X.Y.Z-pre.N: {version}")


def validate_date(date):
    """`YYYY-MM-DD` with a real calendar date."""
    if re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", date):
        year, month, day = int(date[0:4]), int(date[5:7]), int(date[8:10])
        if 1 <= month <= 12 and 1 <= day <= days_in_month(year, month):
            return
    raise ArgumentError(f"date must be YYYY-MM-DD: {date}")


def days_in_month(year, month):
    if month == 2:
        return 29 if is_leap_year(year) else 28
    return 30 if month in (4, 6, 9, 11) else 31


def is_leap_year(year):
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)


def today_utc():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")


def find_version_heading(text, version):
    for index, line in enumerate(split_lines(text)):
        if line.startswith("## "):
            rest = line[len("## ") :]
            if rest.startswith(version) and rest[len(version) :].startswith(" - "):
                return index
    return None


def section_content(text, version):
    """Content after the heading and its blank line, up to the next version
    heading, without trailing blank lines."""
    lines = split_lines(text)
    heading = find_version_heading(text, version)
    if heading is None or heading + 1 >= len(lines) or lines[heading + 1] != "":
        return None
    rest = lines[heading + 2 :]
    end = next((i for i, line in enumerate(rest) if line.startswith("## ")), len(rest))
    content = rest[:end]
    while content and is_blank(content[-1]):
        content.pop()
    return "\n".join(content)


def render_section(fragments, repository):
    if not fragments:
        return NO_CHANGES
    parts = []
    for key, heading in KINDS:
        items = [fragment for fragment in fragments if fragment.kind == key]
        if not items:
            continue
        items.sort(key=lambda f: (not f.breaking, f.number, f.slug))
        entries = []
        for fragment in items:
            prefix = "**Breaking:** " if fragment.breaking else ""
            link = f"https://github.com/{repository}/issues/{fragment.number}"
            entries.append(
                f"- {prefix}{fragment.text} ([#{fragment.number}]({link}))"
            )
        parts.append(f"### {heading}\n\n" + "\n".join(entries))
    return "\n\n".join(parts)


def insert_section(text, block):
    """Inserts `block` before the first version heading, or after the intro
    when there is none, and ends the file with exactly one newline."""
    offset = 0
    for line in split_inclusive(text):
        if line.startswith("## "):
            updated = f"{text[:offset]}{block}\n{text[offset:]}"
            break
        offset += len(line)
    else:
        updated = f"{text.rstrip(chr(10))}\n\n{block}"
    return updated.rstrip("\n") + "\n"


def remove_surface(text, surface):
    """Removes `surface` from the header's `surfaces:` line; every other line is kept."""
    lines = split_lines(text)
    for index in range(1, len(lines)):
        if lines[index] == DELIMITER:
            break
        if lines[index].startswith("surfaces: "):
            value = lines[index][len("surfaces: ") :]
            left = [name for name in value.split(SURFACE_SEPARATOR) if name != surface]
            lines[index] = "surfaces: " + SURFACE_SEPARATOR.join(left)
    return "\n".join(lines) + "\n"


def read_changelog(path):
    text = read_text(path)
    if next(iter(split_lines(text)), None) != CHANGELOG_TITLE:
        raise ChangelogError(f'{path} must start with "{CHANGELOG_TITLE}"')
    return text


def fold(root, config, version, date, surface=None):
    """Writes the version section and deletes the folded fragments. A surface
    fold removes only that surface from shared fragments."""
    validate_version(version)
    validate_date(date)
    changelog = Path(root) / config.changelog_path(surface)
    text = read_changelog(changelog)
    if find_version_heading(text, version) is not None:
        raise ChangelogError(f"{version} already has a section in {changelog}")
    fragments = load_fragments(root, config)
    selected = [fragment for fragment in fragments if fragment.belongs_to(surface)]

    block = f"## {version} - {date}\n\n{render_section(selected, config.repository)}\n"
    write_text(changelog, insert_section(text, block))

    directory = Path(root) / FRAGMENT_DIR
    for fragment in selected:
        path = directory / fragment.file_name
        left = [name for name in fragment.surfaces if name != surface]
        if surface is not None and left:
            write_text(path, remove_surface(read_text(path), surface))
        else:
            remove_file(path)


def notes(root, config, version, surface=None):
    """The release body block for `version`: its section content between
    markers. Fails while fragments of the released product remain unfolded."""
    validate_version(version)
    changelog = Path(root) / config.changelog_path(surface)
    fragments = load_fragments(root, config)
    unfolded = [f.file_name for f in fragments if f.belongs_to(surface)]
    if unfolded:
        raise ChangelogError(
            f"fragments not folded into {version}: {', '.join(unfolded)}"
        )
    text = read_changelog(changelog)
    content = section_content(text, version)
    if content is None:
        raise ChangelogError(f"no section for {version} in {changelog}")
    return f"{START_MARKER}\n{content}\n{END_MARKER}\n"


def check(root, config):
    """Validates every fragment; returns how many there are."""
    return len(load_fragments(root, config))


def parse_command(args):
    """Returns (name, version, surface, date) or raises ArgumentError."""
    if not args:
        raise ArgumentError("missing command", usage=True)
    name, rest = args[0], args[1:]
    if name == "check" and not rest:
        return name, None, None, None
    if name in ("fold", "notes"):
        if not rest:
            raise ArgumentError(f"{name} needs a version", usage=True)
        version, options = rest[0], list(rest[1:])
        surface = None
        date = None
        while options:
            option = options.pop(0)
            if not options:
                raise ArgumentError(f"{option} needs a value", usage=True)
            value = options.pop(0)
            if option == "--surface":
                surface = value
            elif name == "fold" and option == "--date":
                date = value
            else:
                raise ArgumentError(f"unknown option for {name}: {option}", usage=True)
        return name, version, surface, date
    raise ArgumentError(f"unknown command: {name}", usage=True)


def main(argv, root, out=None, err=None):
    """Runs one command against the repository at `root`; returns the exit code."""
    out = out or sys.stdout
    err = err or sys.stderr
    try:
        name, version, surface, date = parse_command(argv)
    except ArgumentError as error:
        print(f"changelog: {error}\n{USAGE}", file=err)
        return 2
    try:
        config = Config.load(Path(root) / CONFIG_FILE)
        if name == "check":
            print(f"changelog: {check(root, config)} fragment(s) valid", file=out)
        elif name == "fold":
            date = date if date is not None else today_utc()
            fold(root, config, version, date, surface)
            print(f"changelog: folded {version} ({date})", file=out)
        else:
            out.write(notes(root, config, version, surface))
    except ChangelogError as error:
        print(f"changelog: {error}", file=err)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], Path(".")))
