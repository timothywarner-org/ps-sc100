"""Obtain a short-lived private network connector registration token through device sign-in.

Set-C3M04PrivateAccess.ps1 -Mode Register runs this helper; you don't run it directly. The
caller supplies an owner-only output folder and deletes the token right after registration.
Nothing else is written: no token cache is persisted, and the token is never printed. Device
sign-in keeps Microsoft's MFA and Conditional Access checks in force for the administrator who
signs in, and it avoids a localhost redirect that this public client doesn't support.

Requires Python 3 and MSAL for Python:  python -m pip install msal
"""
import argparse
import sys
from pathlib import Path

import msal

# Microsoft's first-party application ID for the private network connector, and the delegated
# scope of the connector registration service. Both are public values published in the Microsoft
# Learn article "Create an unattended installation script for the Microsoft Entra private network
# connector". Neither identifies any customer tenant.
CLIENT = "55747057-9b5d-4bd4-b387-abf52a8bd489"
SCOPE = "https://proxy.cloudwebappproxy.net/registerapp/user_impersonation"


def main():
    """Print Microsoft's device sign-in instruction, never the returned token."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--tenant", required=True, help="your Microsoft Entra tenant ID")
    parser.add_argument("--expected-upn", required=True, help="the administrator who must sign in")
    parser.add_argument("--output", type=Path, required=True, help="file that receives the token")
    args = parser.parse_args()

    # The authority names YOUR tenant, so the sign-in can't land in some other directory.
    app = msal.PublicClientApplication(CLIENT, authority=f"https://login.microsoftonline.com/{args.tenant}")
    flow = app.initiate_device_flow(scopes=[SCOPE])
    if "user_code" not in flow:
        raise RuntimeError(flow.get("error_description", "Microsoft did not start device sign-in."))
    print(f"Sign in as {args.expected_upn}.", flush=True)
    print(flow["message"], flush=True)
    result = app.acquire_token_by_device_flow(flow)
    if not result.get("access_token"):
        raise RuntimeError(result.get("error_description", "No connector registration token was issued."))

    # The connector registers to whichever directory issued the token, so check both who and where.
    claims = result.get("id_token_claims", {})
    if str(claims.get("tid", "")).lower() != args.tenant.lower():
        raise RuntimeError("The token came from a different tenant than the one you targeted; registration stopped.")
    signed_in = {str(claims.get(k, "")).lower() for k in ("preferred_username", "upn", "email")} - {""}
    if args.expected_upn.lower() not in signed_in:
        who = ", ".join(sorted(signed_in)) or "an unidentified account"
        raise RuntimeError(f"Signed in as {who}, not {args.expected_upn}; registration stopped.")

    args.output.write_text(result["access_token"], encoding="utf-8")
    print("[PASS] Registration token issued for your tenant.", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # report one clean line to the calling script instead of a traceback
        print(f"[FAIL] {exc}", file=sys.stderr)
        sys.exit(1)
