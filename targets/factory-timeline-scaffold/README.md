# factory-timeline

Aggregate factory agent logs into events, a Markdown summary, and a single
self-contained offline HTML dashboard (timelapse swimlanes).

**stdlib only** · Python **3.12+**.

## Usage (once implemented)

```bash
python -m factory_timeline events /path/to/factory/local
factory-timeline summary ./local
factory-timeline html ./local -o dashboard.html
```
