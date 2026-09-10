#!/usr/bin/env python3
"""Drive Xcode Cloud from the command line through the App Store Connect API.

Lets Claude (or anyone) list workflows, start a build for a branch, watch it finish, and pull
the issues and artefacts (logs, test results) without opening App Store Connect.

Credentials, from an App Store Connect API key (Users and Access > Integrations > App Store Connect API):
  ASC_KEY_ID        the key ID
  ASC_ISSUER_ID     the issuer ID
  ASC_PRIVATE_KEY   the .p8 file contents (PEM), or ASC_PRIVATE_KEY_PATH pointing at the file

Requires: pip install pyjwt cryptography requests

Usage:
  xcode-cloud.py products
  xcode-cloud.py workflows <product-id>
  xcode-cloud.py runs <workflow-id> [--limit N]
  xcode-cloud.py start <workflow-id> <branch>
  xcode-cloud.py status <run-id>
  xcode-cloud.py wait <run-id>
  xcode-cloud.py issues <run-id>
  xcode-cloud.py artifacts <run-id> [--download DIR]
"""
import argparse
import json
import os
import sys
import time

try:
    import jwt
    import requests
except ImportError:
    sys.exit("pip install pyjwt cryptography requests")

API = "https://api.appstoreconnect.apple.com/v1"


def token():
    key = os.environ.get("ASC_PRIVATE_KEY")
    if not key and os.environ.get("ASC_PRIVATE_KEY_PATH"):
        key = open(os.environ["ASC_PRIVATE_KEY_PATH"]).read()
    kid, iss = os.environ.get("ASC_KEY_ID"), os.environ.get("ASC_ISSUER_ID")
    if not (key and kid and iss):
        sys.exit("Set ASC_KEY_ID, ASC_ISSUER_ID and ASC_PRIVATE_KEY (or ASC_PRIVATE_KEY_PATH)")
    now = int(time.time())
    return jwt.encode({"iss": iss, "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"}, key, algorithm="ES256", headers={"kid": kid})


def call(method, path, **kw):
    r = requests.request(method, path if path.startswith("http") else API + path, headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"}, timeout=60, **kw)
    if r.status_code >= 400:
        sys.exit(f"{method} {path} -> {r.status_code}\n{r.text[:2000]}")
    return r.json() if r.text else {}


def rows(items, *attrs):
    for it in items:
        a = it.get("attributes", {})
        print(it["id"], *[str(a.get(x)) for x in attrs], sep="  ")


def cmd_products(_):
    rows(call("GET", "/ciProducts")["data"], "name", "productType")


def cmd_workflows(a):
    rows(call("GET", f"/ciProducts/{a.product_id}/workflows")["data"], "name", "isEnabled")


def cmd_runs(a):
    data = call("GET", f"/ciWorkflows/{a.workflow_id}/buildRuns", params={"sort": "-number", "limit": a.limit})["data"]
    rows(data, "number", "executionProgress", "completionStatus", "createdDate")


def branch_reference(workflow_id, branch):
    repo = call("GET", f"/ciWorkflows/{workflow_id}/repository")["data"]
    refs = call("GET", f"/scmRepositories/{repo['id']}/gitReferences", params={"limit": 200})["data"]
    for ref in refs:
        at = ref["attributes"]
        if at.get("kind") == "BRANCH" and at.get("name") == branch:
            return ref["id"]
    sys.exit(f"Branch {branch!r} not found in repository {repo['attributes'].get('repositoryName')}")


def cmd_start(a):
    ref_id = branch_reference(a.workflow_id, a.branch)
    body = {"data": {"type": "ciBuildRuns", "relationships": {
        "workflow": {"data": {"type": "ciWorkflows", "id": a.workflow_id}},
        "sourceBranchOrTag": {"data": {"type": "scmGitReferences", "id": ref_id}},
    }}}
    run = call("POST", "/ciBuildRuns", data=json.dumps(body))["data"]
    print(run["id"], run["attributes"].get("number"))


def run_status(run_id):
    at = call("GET", f"/ciBuildRuns/{run_id}")["data"]["attributes"]
    return at.get("executionProgress"), at.get("completionStatus"), at


def cmd_status(a):
    progress, status, at = run_status(a.run_id)
    print(progress, status, at.get("startedDate"), at.get("finishedDate"))


def cmd_wait(a):
    while True:
        progress, status, _ = run_status(a.run_id)
        print(progress, status or "")
        if progress == "COMPLETE":
            sys.exit(0 if status == "SUCCEEDED" else 1)
        time.sleep(30)


def actions(run_id):
    return call("GET", f"/ciBuildRuns/{run_id}/actions")["data"]


def cmd_issues(a):
    for act in actions(a.run_id):
        name = act["attributes"].get("name")
        for issue in call("GET", f"/ciBuildActions/{act['id']}/issues", params={"limit": 200})["data"]:
            at = issue["attributes"]
            loc = at.get("fileSource") or {}
            print(f"[{name}] {at.get('issueType')}: {at.get('message')}  {loc.get('path','')}:{loc.get('lineNumber','')}")


def cmd_artifacts(a):
    for act in actions(a.run_id):
        name = act["attributes"].get("name")
        for art in call("GET", f"/ciBuildActions/{act['id']}/artifacts")["data"]:
            at = art["attributes"]
            print(f"[{name}] {at.get('fileType')} {at.get('fileName')} {at.get('fileSize')} bytes")
            if a.download and at.get("downloadUrl"):
                os.makedirs(a.download, exist_ok=True)
                dest = os.path.join(a.download, at["fileName"])
                with requests.get(at["downloadUrl"], stream=True, timeout=300) as r:
                    with open(dest, "wb") as f:
                        for chunk in r.iter_content(1 << 16):
                            f.write(chunk)
                print("  saved", dest)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("products").set_defaults(fn=cmd_products)
    s = sub.add_parser("workflows"); s.add_argument("product_id"); s.set_defaults(fn=cmd_workflows)
    s = sub.add_parser("runs"); s.add_argument("workflow_id"); s.add_argument("--limit", type=int, default=5); s.set_defaults(fn=cmd_runs)
    s = sub.add_parser("start"); s.add_argument("workflow_id"); s.add_argument("branch"); s.set_defaults(fn=cmd_start)
    s = sub.add_parser("status"); s.add_argument("run_id"); s.set_defaults(fn=cmd_status)
    s = sub.add_parser("wait"); s.add_argument("run_id"); s.set_defaults(fn=cmd_wait)
    s = sub.add_parser("issues"); s.add_argument("run_id"); s.set_defaults(fn=cmd_issues)
    s = sub.add_parser("artifacts"); s.add_argument("run_id"); s.add_argument("--download"); s.set_defaults(fn=cmd_artifacts)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
