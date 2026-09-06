import base64,hmac,hashlib,json,sys
key=b"ica-1.26-jwt-secret"
role=sys.argv[1] if len(sys.argv)>1 else "user"
def b(x): return base64.urlsafe_b64encode(x).rstrip(b"=").decode()
h=b(json.dumps({"alg":"HS256","typ":"JWT","kid":"lab-key"},separators=(",",":")).encode())
p=b(json.dumps({"iss":"https://issuer.example.test","sub":role+"-alice","aud":"payment-api","role":role},separators=(",",":")).encode())
m=(h+"."+p).encode()
print(h+"."+p+"."+b(hmac.new(key,m,hashlib.sha256).digest()))
