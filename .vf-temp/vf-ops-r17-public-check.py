#!/usr/bin/env python3
import json
import os
import socket
import ssl
import subprocess
import time
from datetime import datetime, timezone
from urllib.parse import urljoin, urlparse

import requests
from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.chrome.service import Service

BASES = [
    "https://www3.m3u8.one",
    "https://ilovem3u8.pages.dev",
    "https://cb63b8c9.ilovem3u8.pages.dev",
    "https://19d882ca.ilovem3u8.pages.dev",
    "https://4906c69c.ilovem3u8.pages.dev",
    "https://cb7c511d.ilovem3u8.pages.dev",
    "https://19161550.ilovem3u8.pages.dev",
]
HTTP_PATHS = [
    "/", "/zh/", "/sitemap.xml", "/robots.txt", "/404.html",
    "/problems/", "/zh/problems/", "/m3u8-player/", "/vf-r17-missing-page-404/",
]
BROWSER_PATHS = [
    "/", "/zh/", "/404.html", "/problems/", "/zh/problems/", "/m3u8-player/", "/vf-r17-missing-page-404/",
]
VIEWPORTS = [(390, 844), (768, 1024), (1440, 1000)]


def utcnow():
    return datetime.now(timezone.utc).isoformat()


def dns_info(host):
    out = {"host": host, "addresses": [], "error": None}
    try:
        infos = socket.getaddrinfo(host, 443, proto=socket.IPPROTO_TCP)
        out["addresses"] = sorted({item[4][0] for item in infos})
    except Exception as exc:
        out["error"] = f"{type(exc).__name__}: {exc}"
    return out


def tls_info(host):
    out = {"host": host, "subject": None, "issuer": None, "notBefore": None, "notAfter": None, "error": None}
    try:
        context = ssl.create_default_context()
        with socket.create_connection((host, 443), timeout=15) as sock:
            with context.wrap_socket(sock, server_hostname=host) as ssock:
                cert = ssock.getpeercert()
        out["subject"] = dict(x[0] for x in cert.get("subject", []))
        out["issuer"] = dict(x[0] for x in cert.get("issuer", []))
        out["notBefore"] = cert.get("notBefore")
        out["notAfter"] = cert.get("notAfter")
    except Exception as exc:
        out["error"] = f"{type(exc).__name__}: {exc}"
    return out


def http_check(base):
    session = requests.Session()
    session.headers["User-Agent"] = "VF-Ops-R17-Public-Validation/1.0"
    results = []
    for path in HTTP_PATHS:
        url = urljoin(base + "/", path.lstrip("/"))
        item = {"url": url, "status": None, "finalUrl": None, "contentType": None, "bytes": 0, "elapsedMs": None, "server": None, "cfRay": None, "title": None, "canonical": None, "error": None}
        started = time.time()
        try:
            response = session.get(url, timeout=25, allow_redirects=True)
            item["elapsedMs"] = round((time.time() - started) * 1000, 1)
            item["status"] = response.status_code
            item["finalUrl"] = response.url
            item["contentType"] = response.headers.get("content-type")
            item["server"] = response.headers.get("server")
            item["cfRay"] = response.headers.get("cf-ray")
            item["bytes"] = len(response.content)
            text = response.text[:500000] if "text" in (item["contentType"] or "") or "html" in (item["contentType"] or "") or "xml" in (item["contentType"] or "") else ""
            lower = text.lower()
            if "<title" in lower:
                import re
                match = re.search(r"<title[^>]*>(.*?)</title>", text, re.I | re.S)
                if match:
                    item["title"] = " ".join(match.group(1).split())[:300]
            if "canonical" in lower:
                import re
                match = re.search(r"<link[^>]+rel=[\"']canonical[\"'][^>]+href=[\"']([^\"']+)", text, re.I)
                if not match:
                    match = re.search(r"<link[^>]+href=[\"']([^\"']+)[\"'][^>]+rel=[\"']canonical[\"']", text, re.I)
                if match:
                    item["canonical"] = match.group(1)
        except Exception as exc:
            item["elapsedMs"] = round((time.time() - started) * 1000, 1)
            item["error"] = f"{type(exc).__name__}: {exc}"
        results.append(item)
    return results


def make_driver(width, height):
    options = Options()
    options.binary_location = os.environ.get("CHROME_BIN", "/usr/bin/google-chrome")
    options.add_argument("--headless=new")
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--ignore-certificate-errors")
    options.add_argument(f"--window-size={width},{height}")
    options.set_capability("goog:loggingPrefs", {"browser": "ALL", "performance": "ALL"})
    service = Service(os.environ.get("CHROMEDRIVER", "/usr/bin/chromedriver"))
    driver = webdriver.Chrome(service=service, options=options)
    driver.set_page_load_timeout(35)
    driver.set_script_timeout(20)
    return driver


def browser_checks(base):
    results = []
    for width, height in VIEWPORTS:
        for path in BROWSER_PATHS:
            url = urljoin(base + "/", path.lstrip("/"))
            item = {"url": url, "viewport": [width, height], "finalUrl": None, "title": None, "canonical": None, "lang": None, "readyState": None, "scrollWidth": None, "clientWidth": None, "overflow": None, "consoleErrors": [], "networkFailures": [], "badResponses": [], "elapsedMs": None, "error": None}
            driver = None
            started = time.time()
            try:
                driver = make_driver(width, height)
                driver.get(url)
                time.sleep(1.0)
                item["elapsedMs"] = round((time.time() - started) * 1000, 1)
                item["finalUrl"] = driver.current_url
                item["title"] = driver.title
                item["readyState"] = driver.execute_script("return document.readyState")
                item["canonical"] = driver.execute_script("const e=document.querySelector('link[rel=canonical]'); return e?e.href:null;")
                item["lang"] = driver.execute_script("return document.documentElement.lang || null")
                dims = driver.execute_script("return {scrollWidth:document.documentElement.scrollWidth, clientWidth:document.documentElement.clientWidth};")
                item["scrollWidth"] = dims.get("scrollWidth")
                item["clientWidth"] = dims.get("clientWidth")
                item["overflow"] = bool(item["scrollWidth"] and item["clientWidth"] and item["scrollWidth"] > item["clientWidth"] + 2)
                for entry in driver.get_log("browser"):
                    if entry.get("level") in ("SEVERE", "ERROR"):
                        item["consoleErrors"].append(entry.get("message", "")[:1000])
                for entry in driver.get_log("performance"):
                    try:
                        msg = json.loads(entry["message"])["message"]
                    except Exception:
                        continue
                    method = msg.get("method")
                    params = msg.get("params", {})
                    if method == "Network.loadingFailed":
                        item["networkFailures"].append({"errorText": params.get("errorText"), "blockedReason": params.get("blockedReason"), "type": params.get("type")})
                    elif method == "Network.responseReceived":
                        response = params.get("response", {})
                        status = response.get("status")
                        rurl = response.get("url", "")
                        if isinstance(status, (int, float)) and status >= 400 and not (path.startswith("/vf-r17-missing") and int(status) == 404):
                            item["badResponses"].append({"status": status, "url": rurl[:500]})
            except Exception as exc:
                item["elapsedMs"] = round((time.time() - started) * 1000, 1)
                item["error"] = f"{type(exc).__name__}: {exc}"
            finally:
                if driver is not None:
                    try:
                        driver.quit()
                    except Exception:
                        pass
            results.append(item)
    return results


def summarize(base_report):
    http = base_report["http"]
    browser = base_report["browser"]
    reachable = any(x.get("status") is not None for x in http)
    http_ok = sum(1 for x in http if x.get("status") and (200 <= x["status"] < 400 or ("vf-r17-missing" in x["url"] and x["status"] == 404)))
    browser_ok = sum(1 for x in browser if not x.get("error") and not x.get("consoleErrors") and not x.get("networkFailures") and not x.get("badResponses") and not x.get("overflow"))
    return {
        "reachable": reachable,
        "httpPass": f"{http_ok}/{len(http)}",
        "browserPass": f"{browser_ok}/{len(browser)}",
        "consoleErrors": sum(len(x.get("consoleErrors", [])) for x in browser),
        "networkFailures": sum(len(x.get("networkFailures", [])) for x in browser),
        "badResponses": sum(len(x.get("badResponses", [])) for x in browser),
        "overflow": sum(1 for x in browser if x.get("overflow")),
    }


def main():
    report = {"generatedAt": utcnow(), "runner": {}, "bases": []}
    report["runner"]["chrome"] = subprocess.run([os.environ.get("CHROME_BIN", "/usr/bin/google-chrome"), "--version"], text=True, capture_output=True).stdout.strip()
    report["runner"]["chromedriver"] = subprocess.run([os.environ.get("CHROMEDRIVER", "/usr/bin/chromedriver"), "--version"], text=True, capture_output=True).stdout.strip()
    for base in BASES:
        host = urlparse(base).hostname
        base_report = {"base": base, "dns": dns_info(host), "tls": tls_info(host), "http": http_check(base), "browser": []}
        if base_report["dns"]["addresses"]:
            base_report["browser"] = browser_checks(base)
        base_report["summary"] = summarize(base_report)
        report["bases"].append(base_report)
    report["accessibleBases"] = [x["base"] for x in report["bases"] if x["summary"]["reachable"]]
    report["allInaccessible"] = len(report["accessibleBases"]) == 0
    with open("vf-ops-r17-public-validation.json", "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)
    lines = ["# vf-ops R17 公共链路自动验收", "", f"生成时间：{report['generatedAt']}", "", f"Chrome：{report['runner']['chrome']}", "", "| 地址 | DNS | HTTP | 浏览器 | Console | Network | 4xx/5xx | 溢出 |", "|---|---:|---:|---:|---:|---:|---:|---:|"]
    for x in report["bases"]:
        s = x["summary"]
        lines.append(f"| {x['base']} | {'PASS' if x['dns']['addresses'] else 'FAIL'} | {s['httpPass']} | {s['browserPass']} | {s['consoleErrors']} | {s['networkFailures']} | {s['badResponses']} | {s['overflow']} |")
    lines.extend(["", "## 可访问地址", "", *(report["accessibleBases"] or ["无"]), ""])
    with open("vf-ops-r17-public-validation.md", "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print(json.dumps({"accessibleBases": report["accessibleBases"], "summaries": {x["base"]: x["summary"] for x in report["bases"]}}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
