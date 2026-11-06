#!/usr/bin/python3
"""Submit a PKCS#10 request to an AD CS CA over DCOM (MS-WCCE ICertRequestD::Request, opnum 3).

  mld-cert-dcom DC_FQDN CA_NAME TEMPLATE CSR_DER OUT_CERT_DER

Authentication is Kerberos from $KRB5CCNAME (the machine ticket or the user ticket).
The private key stays in the TPM: only the request goes to the CA.
Exit 0 = issued, 2 = pending, 1 = denied or error.
"""
import os
import sys

from impacket.dcerpc.v5.dcomrt import DCOMANSWER, DCOMCALL, DCOMConnection, IRemUnknown2
from impacket.dcerpc.v5.dtypes import DWORD, LPWSTR, ULONG
from impacket.dcerpc.v5.ndr import NDRPOINTER, NDRSTRUCT, NDRUniConformantArray
from impacket.dcerpc.v5.rpcrt import RPC_C_AUTHN_LEVEL_PKT_PRIVACY
from impacket.krb5.ccache import CCache
from impacket.uuid import string_to_bin, uuidtup_to_bin

CLSID_CERT_REQUEST = string_to_bin("D99E6E74-FC88-11D0-B498-00A0C90312F3")
IID_ICERT_REQUEST_D = uuidtup_to_bin(("D99E6E70-FC88-11D0-B498-00A0C90312F3", "0.0"))
DISPOSITION = {3: "issued", 5: "pending"}


class BYTE_ARRAY(NDRUniConformantArray):
    item = "c"


class PBYTE(NDRPOINTER):
    referent = (("Data", BYTE_ARRAY),)


class CERTTRANSBLOB(NDRSTRUCT):
    structure = (("cb", ULONG), ("pb", PBYTE))


class Request(DCOMCALL):
    opnum = 3
    structure = (
        ("dwFlags", DWORD),
        ("pwszAuthority", LPWSTR),
        ("pdwRequestId", DWORD),
        ("pwszAttributes", LPWSTR),
        ("pctbRequest", CERTTRANSBLOB),
    )


class RequestResponse(DCOMANSWER):
    structure = (
        ("pdwRequestId", DWORD),
        ("pdwDisposition", ULONG),
        ("pctbCertChain", CERTTRANSBLOB),
        ("pctbEncodedCert", CERTTRANSBLOB),
        ("pctbDispositionMessage", CERTTRANSBLOB),
        ("ErrorCode", ULONG),
    )


def blob(data: bytes) -> CERTTRANSBLOB:
    b = CERTTRANSBLOB()
    b["cb"] = len(data)
    b["pb"] = data
    return b


def blob_bytes(b) -> bytes:
    data = b["pb"]
    return b"".join(data) if isinstance(data, list) else bytes(data or b"")


def main():
    dc, ca, template, csr_path, out_path = sys.argv[1:6]
    # krb5.conf default_ccache_name is FILE:/tmp/krb5cc_%{uid}. impacket reads KRB5CCNAME only.
    # impacket opens $KRB5CCNAME as a plain path: remove the "FILE:" type prefix.
    ccpath = os.environ.get("KRB5CCNAME", f"/tmp/krb5cc_{os.getuid()}").removeprefix("FILE:")
    os.environ["KRB5CCNAME"] = ccpath
    ccache = CCache.loadFile(ccpath)
    principal = ccache.principal.prettyPrint().decode()
    user, realm = principal.split("@", 1)

    dcom = DCOMConnection(dc, user, "", realm, "", "", None, oxidResolver=True, doKerberos=True, kdcHost=dc)
    try:
        iface = dcom.CoCreateInstanceEx(CLSID_CERT_REQUEST, IID_ICERT_REQUEST_D)
        iface.get_cinstance().set_auth_level(RPC_C_AUTHN_LEVEL_PKT_PRIVACY)
        unk = IRemUnknown2(iface)

        req = Request()
        req["dwFlags"] = 0  # CR_IN_FORMATANY: the CA detects PKCS#10.
        req["pwszAuthority"] = ca + "\x00"
        req["pdwRequestId"] = 0
        req["pwszAttributes"] = f"CertificateTemplate:{template}\x00"
        with open(csr_path, "rb") as f:
            req["pctbRequest"] = blob(f.read())

        resp = unk.request(req, iid=IID_ICERT_REQUEST_D, uuid=iface.get_iPid())
    finally:
        dcom.disconnect()

    disp = resp["pdwDisposition"]
    msg = blob_bytes(resp["pctbDispositionMessage"]).decode("utf-16-le", "replace").rstrip("\x00").strip()
    print(f"request {resp['pdwRequestId']}: {DISPOSITION.get(disp, f'disposition {disp:#x}')} {msg}", file=sys.stderr)
    if disp == 5:
        sys.exit(2)
    if disp != 3:
        sys.exit(1)
    with open(out_path, "wb") as f:
        f.write(blob_bytes(resp["pctbEncodedCert"]))


if __name__ == "__main__":
    main()
