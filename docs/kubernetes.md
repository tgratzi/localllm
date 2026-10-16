# Running on Kubernetes (TOS)

**One sentence:** the same Gemma image runs as a TOS app in the cluster, reachable only from
other pods at `http://localllm:8080/v1`, with an API key kept in a Kubernetes Secret.

## What gets installed

`tos apps install localllm-<version>.tar` installs the Helm chart in [charts/localllm](../charts/localllm):

| Object | Name | Purpose |
| --- | --- | --- |
| Deployment | `localllm` | One `llama-server` pod. UID 10001, read-only filesystem, no capabilities, no service-account token. |
| Service | `localllm` (ClusterIP, port 8080) | The address apps call. Not exposed outside the cluster. |
| Secret | `localllm-api-key` (key `api_key`) | Random 48-character API key, made on first install and kept on upgrades. |

The `.tar` holds the chart and the image (~5 GB). The TOS node needs no internet access and
no access to any registry.

## Build the package

The GitHub workflow [release-tupack.yml](../.github/workflows/release-tupack.yml) does this on
every `v*` tag and attaches the result to a GitHub Release. To build by hand (Linux, macOS,
WSL or Git Bash, with Docker running):

```bash
scripts/build-image.sh                                  # gemma-e2b-server:local
TUPACK=/path/to/baseimage7/src/scripts/tupack \
  scripts/build-tupack.sh v1.0.0                        # dist/localllm-1.0.0.tar + .sha256
```

`tupack` only exists in the private repo `tufin-ext-resources/baseimage7`
(`src/scripts/tupack`). The workflow reads it with the `BASEIMAGE_TOKEN` secret.

## Install [TOS node]

From a GitHub Release, download all `.part-NN` files and the `.sha256` file, then:

```bash
cat localllm-1.0.0.tar.part-* > localllm-1.0.0.tar
sha256sum -c localllm-1.0.0.tar.sha256       # must print OK
tos apps install localllm-1.0.0.tar          # first time
tos apps upgrade localllm-1.0.0.tar          # newer version over an existing install
```

Check it:

```bash
kubectl get pod -l app=localllm               # wait for 1/1 Running (startup takes up to a few minutes)
kubectl logs deploy/localllm --tail 50
kubectl run llm-test --rm -i --restart=Never --image=tos-registry.local/localllm/gemma-e2b-server:1.0.0 \
  --command -- curl -s http://localllm:8080/health              # {"status":"ok"}
```

Remove it: `tos apps uninstall localllm`. That also deletes the Secret, so a later install
gets a new key.

## Use it from another app

Two settings, both from inside the cluster:

- **URL:** `http://localllm:8080/v1` from the same namespace (TOS apps run in `default`);
  `http://localllm.default.svc.cluster.local:8080/v1` from any namespace.
- **Key:** mount Secret `localllm-api-key` into your pod and read the file. Example for a
  Deployment:

```yaml
containers:
  - name: my-app
    env:
      - name: LLM_BASE_URL
        value: http://localllm:8080/v1
      - name: LLM_API_KEY_FILE
        value: /run/secrets/localllm/api_key
    volumeMounts:
      - name: localllm-key
        mountPath: /run/secrets/localllm
        readOnly: true
volumes:
  - name: localllm-key
    secret:
      secretName: localllm-api-key
      optional: true    # your app still starts when localllm isn't installed
```

Python, with no extra libraries beyond `requests`:

```python
import os, requests

def ask_llm(prompt: str) -> str:
    with open(os.environ["LLM_API_KEY_FILE"]) as f:   # read each time: the key can change on reinstall
        key = f.read().strip()
    r = requests.post(
        f"{os.environ['LLM_BASE_URL']}/chat/completions",
        headers={"Authorization": f"Bearer {key}"},
        json={"model": "gemma", "messages": [{"role": "user", "content": prompt}], "max_tokens": 256},
        timeout=300,
    )
    r.raise_for_status()
    return r.json()["choices"][0]["message"]["content"]
```

Rules for callers:

- **Expect slow answers.** On CPU, one reply takes seconds to a minute, and with
  `llm.parallel: 1` requests queue behind each other. Call it from background jobs, not
  inside a web request that has a short timeout.
- **Read the key file, don't copy it into an env var.** Mounted Secrets update in place
  (within about a minute), environment variables don't.
- Never send the key to a browser. Don't log the `Authorization` header or sensitive prompts.

## Settings

Defaults are in [values.yaml](../charts/localllm/values.yaml). `llm.*` map to the same
`llama-server` settings as the `GEMMA_*` variables described in [architecture.md](architecture.md).
The resource defaults request 2 CPUs and 6 GiB, with a 10 GiB memory limit. Check that the
TOS node has that much free before installing: `kubectl describe node | grep -A8 "Allocated resources"`.

## Bundling into another app's package

`tupack` collects every image that appears in a chart's rendered manifests. To ship localllm
inside another app's `.tar` (for example RLM), copy this chart's templates into that app's
chart (or add it as a Helm dependency in `charts/`), keep the `image.registry` /
`image.repository` split, and point the image at a registry the build can pull from. The
trade-off: every release of that app then carries the extra ~5 GB, and the model can't be
upgraded on its own.

## Limits and things not yet verified

- **Plain HTTP inside the cluster.** Traffic between pods is not encrypted, as in the VM setup.
- **Any pod in the cluster can reach port 8080.** The API key is what stops other pods. To
  restrict by network too, add a NetworkPolicy; k3s enforces them.
- **Not yet tried on a real TOS node.** The package builds with tupack and the chart passes
  `helm lint`, but `tos apps install` itself hasn't been run against this package. If `tos apps install`
  renders charts without cluster access, `lookup` finds nothing and a new key is made on each
  upgrade. That still works, because the pod restarts on every upgrade and callers re-read the file.
