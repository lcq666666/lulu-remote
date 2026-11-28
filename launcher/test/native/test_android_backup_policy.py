"""Verify the backup policy in source or in the packaged Android launcher."""

import re
import subprocess
import sys
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ANDROID = "{http://schemas.android.com/apk/res/android}"
MAIN = Path(__file__).resolve().parents[2] / "android/app/src/main"
RULES = "res/xml/device_data_rules.xml"


def verify(manifest, rules, rules_reference="@xml/device_data_rules"):
    app = manifest.find("application")
    if app is None:
        raise ValueError("Android launcher manifest lacks an application")
    for key in ("allowBackup", "fullBackupContent"):
        if app.get(ANDROID + key) != "false":
            raise ValueError("Android launcher must set " + key + " to false")
    if app.get(ANDROID + "dataExtractionRules") != rules_reference:
        raise ValueError("Android launcher must reference the device data rules")
    if rules.tag != "data-extraction-rules":
        raise ValueError("Invalid Android device data rules")
    for transport in ("cloud-backup", "device-transfer"):
        entries = rules.findall(f"{transport}/exclude")
        if not any(entry.get("domain") == "sharedpref" and entry.get("path") == "."
                   for entry in entries):
            raise ValueError("Android preferences must stay local during " + transport)


def read_binary_xml(aapt, apk, path):
    dump = subprocess.check_output(
        [aapt, "dump", "xmltree", apk, "--file", path], encoding="utf-8"
    )
    stack = []
    root = None
    for line in dump.splitlines():
        if match := re.fullmatch(r"( *)E: ([^ ]+) \(line=[0-9]+\)", line):
            depth, tag = len(match[1]), match[2]
            while stack and stack[-1][0] >= depth:
                stack.pop()
            if stack:
                element = ET.SubElement(stack[-1][1], tag)
            else:
                root = element = ET.Element(tag)
            stack.append((depth, element))
        elif stack and (match := re.fullmatch(r" *A: ([^ (=]+)(?:\(0x[0-9a-f]+\))?=(.*)", line)):
            key = match[1].replace(ANDROID[1:-1] + ":", ANDROID, 1)
            value = match[2].split(" (Raw: ", 1)[0].strip('"')
            stack[-1][1].set(key, value)
    if root is None:
        raise ValueError("Could not read APK XML: " + path)
    return root


def verify_apk(aapt, apk):
    # Release builds may shorten resource paths to e.g. res/zn.xml. Resolve
    # the file via the resource table and require the manifest to use its ID.
    table = subprocess.check_output([aapt, "dump", "resources", apk], encoding="utf-8")
    resource = re.search(
        r"(?m)^ *resource (0x[0-9a-f]+) xml/device_data_rules(?: [^\n]*)?\n"
        r" *\(\) \(file\) (res/[^ ]+\.xml) type=XML$",
        table,
    )
    if resource is None:
        raise ValueError("Packaged Android launcher lacks the device data rules")
    manifest = read_binary_xml(aapt, apk, "AndroidManifest.xml")
    rules = read_binary_xml(aapt, apk, resource[2])
    verify(manifest, rules, "@" + resource[1])


class AndroidBackupPolicyTest(unittest.TestCase):
    def setUp(self):
        self.manifest = ET.parse(MAIN / "AndroidManifest.xml").getroot()
        self.rules = ET.parse(MAIN / RULES).getroot()

    def test_launcher_policy(self):
        verify(self.manifest, self.rules)

    def test_rejects_missing_rules_reference(self):
        self.manifest.find("application").attrib.pop(ANDROID + "dataExtractionRules")
        with self.assertRaisesRegex(ValueError, "reference"):
            verify(self.manifest, self.rules)

    def test_rejects_cloud_backup_enabled(self):
        self.manifest.find("application").set(ANDROID + "allowBackup", "true")
        with self.assertRaisesRegex(ValueError, "allowBackup"):
            verify(self.manifest, self.rules)

    def test_rejects_partial_device_transfer_exclusion(self):
        entry = self.rules.find("device-transfer/exclude[@domain='sharedpref']")
        entry.set("path", "FlutterSecureStorage.xml")
        with self.assertRaisesRegex(ValueError, "device-transfer"):
            verify(self.manifest, self.rules)


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--apk":
        try:
            verify_apk(*sys.argv[2:])
        except (ValueError, subprocess.CalledProcessError) as error:
            sys.exit(str(error))
        print("Verified launcher APK backup policy")
    else:
        unittest.main()
