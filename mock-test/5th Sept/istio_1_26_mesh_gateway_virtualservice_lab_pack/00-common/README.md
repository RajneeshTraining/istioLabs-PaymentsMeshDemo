# Common setup

Run:

```bash
kubectl apply -f setup.yaml
kubectl get pods -n mesh-gateway-labs
```

The test client is `deploy/curl`.

If your cluster cannot pull `curlimages/curl` or `kennethreitz/httpbin`, replace the images with images available in your environment.
