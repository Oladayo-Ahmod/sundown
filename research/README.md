# research/

Offline analysis only. Nothing here is deployed or imported by `contracts/src`.

- Python 3.11, dependencies pinned in `requirements.txt` (compiled from `requirements.in` with `uv pip compile`).
- `data/raw/` is git-ignored: raw vendor data is never committed.

```bash
uv venv --python 3.11 .venv && source .venv/bin/activate
uv pip install -r requirements.txt
ruff check .
```
