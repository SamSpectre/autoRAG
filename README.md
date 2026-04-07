# AutoRAG: Self-Improving RAG System

An autonomous system that optimizes its own RAG pipeline -- not just prompts, but chunking, embeddings, model routing, retrieval parameters, and pipeline topology -- all tuned autonomously against Meta's [CRAG benchmark](https://github.com/facebookresearch/CRAG) across 5 domains.

Applies [Karpathy's autoresearch](https://github.com/karpathy/autoresearch) pattern to the entire RAG stack instead of model training.

## Results

```
                       Baseline    Optimized    Change
crag_score:            0.208       0.360        +73%
accuracy:              39.4%       46.0%        +17%
hallucination_rate:    18.6%       10.0%        -46%
```

18 experiments run autonomously. 5 kept, 13 discarded. No human in the loop.

### What the Optimizer Learned

| Experiment | Change | Score | Verdict |
|---|---|---|---|
| 002 | Raise confidence threshold 0.70 to 0.85 | 0.208 -> 0.260 | **keep** |
| 003 | Better false premise detection (5 categories + examples) | 0.260 -> 0.310 | **keep** |
| 005 | Stricter hallucination patterns in validator | 0.310 -> 0.320 | **keep** |
| 009 | Lower threshold 0.85 to 0.80 (sweet spot) | 0.320 -> 0.330 | **keep** |
| 011 | Upgrade validator from Haiku to Sonnet | 0.330 -> 0.360 | **keep** |

Key discoveries (without human guidance):
- **Hallucination is the bottleneck, not accuracy.** Each incorrect answer costs -1.0 while "I don't know" costs 0.0. The optimizer learned to prioritize reducing hallucination over increasing recall.
- **Confidence threshold has a sweet spot.** Too low (0.70) lets hallucinations through. Too high (0.85) blocks correct answers. The optimizer found 0.80 through two experiments.
- **More expensive models aren't always better.** Upgrading the classifier to Sonnet added 48% cost with zero score improvement. But upgrading the validator to Sonnet improved score by +0.030.
- **More context can hurt.** Increasing top_k from 5 to 7-8 added noise that increased hallucination.
- **Smaller chunks hurt.** Chunk size 256 produced fragments too small for coherent answers.

## How It Works

```
                    INNER PIPELINE (per question)
                    ==============================
User Question
     |
     v
[Query Classifier]  -->  domain + type + false premise?     (Haiku)
     |
     v
[Query Rewriter]    -->  optimized search query              (Haiku)
     |
     v
[LanceDB Retrieval] -->  top 5 relevant chunks              (vector search)
     |
     v
[Answer Generator]  -->  candidate answer                    (Sonnet)
     |
     v
[Answer Validator]  -->  final answer or "I don't know"      (Sonnet)


                    OUTER LOOP (autonomous)
                    ========================
              +---> Read results.tsv (experiment history)
              |     Read config.yaml + agents/skills/*.md
              |
              +---> Make ONE change (prompt, config param, or model route)
              |
              +---> Re-index if chunking/embedding changed
              |
              +---> Run evaluate.py on 500-question CRAG dev set
              |
              +---> crag_score improved?
              |      YES --> git commit (keep)
              |      NO  --> git checkout (discard)
              |
              +---> Log to results.tsv, LOOP BACK
```

### The Autoresearch Mapping

| Karpathy's autoresearch | Project 1 (Financial) | Project 2 (AutoRAG) |
|---|---|---|
| `prepare.py` (fixed eval) | `evaluate.py` (fixed eval) | `evaluate.py` (fixed eval) |
| `train.py` (agent edits) | `agents/skills/*.md` | `config.yaml` + `agents/skills/*.md` |
| `val_bpb` (metric) | `composite_score` | `crag_score` |
| `program.md` (strategy) | `optimizer_program.md` | `optimizer_program.md` |
| 5-min GPU budget | ~$1.80 API budget | ~$0.78-$3.89 API budget |
| git keep/discard | git keep/discard | git keep/discard |

### What Project 2 Adds Over Project 1

Project 1 had **1 optimization dimension** (edit skill file text).
Project 2 has **7 optimization dimensions:**

| # | Dimension | Config Location | Re-index? |
|---|---|---|---|
| 1 | Agent prompts | `agents/skills/*.md` | No |
| 2 | Retrieval parameters | `config.yaml` retrieval | No |
| 3 | Model routing | `config.yaml` models | No |
| 4 | Pipeline topology | `config.yaml` pipeline | No |
| 5 | Few-shot examples | `config.yaml` few_shot | No |
| 6 | Chunking strategy | `config.yaml` chunking | Yes |
| 7 | Embedding model | `config.yaml` embedding | Yes |

The optimizer learns that dimensions 1-5 are cheap experiments (~$0.78 per eval) and 6-7 are expensive (~$0.78 + 30 min re-indexing). It naturally front-loads cheap experiments.

## Evaluation

CRAG scoring (per-question):
- **Perfect (1.0):** correct answer
- **Acceptable (0.5):** partially correct
- **Missing (0.0):** "I don't know" or no answer
- **Incorrect (-1.0):** wrong or hallucinated

Composite metric: `crag_score = accuracy - hallucination_rate`

Scoring uses a single LLM judge (Claude Haiku) for consistency across experiments. Official CRAG evaluation uses dual judges (ChatGPT + Llama 3).

### Benchmark

| Domain | Baseline | Optimized |
|---|---|---|
| Finance | 0.10 | -- |
| Sports | 0.19 | -- |
| Movie | 0.14 | -- |
| Music | 0.28 | -- |
| Open | 0.33 | -- |

500 questions, 5 domains, 8 question types. Dev/test split stratified by domain.

## Quick Start

### Prerequisites

- Python 3.12+
- [uv](https://docs.astral.sh/uv/) package manager
- API keys: Anthropic (Claude), OpenAI (embeddings)

### Setup

```bash
# Install dependencies
uv sync

# Set API keys
cp .env.example .env
# Edit .env with your keys

# Download CRAG dataset (~5.5 GB, one-time)
uv run scripts/download_crag.py

# Build vector index (~30 min, eval-only docs)
uv run scripts/build_index.py --eval-only --force

# Run baseline evaluation (~60 min, ~$3.89)
uv run evaluate.py --split dev
```

### Single Query Test

```bash
uv run -m agents.pipeline --query "who won the NFL MVP?" --verbose
```

### Start the Optimizer

```powershell
# Windows (PowerShell)
.\scripts\run_optimizer.ps1

# Linux/Mac
./scripts/run_optimizer.sh
```

The optimizer runs continuously with a $15 budget cap, making one focused change per iteration, keeping improvements and discarding regressions. Check `results.tsv` for progress.

## Project Structure

```
evaluate.py                  # FIXED. CRAG scoring harness (never modified)
config.yaml                  # TUNABLE. All 7 optimization dimensions
optimizer_program.md         # Instructions for the optimizer agent
results.tsv                  # Experiment log (keep/discard history)
pyproject.toml               # Dependencies
.env                         # API keys (ANTHROPIC, OPENAI)

agents/
  pipeline.py                # FIXED. Orchestrates the 5-stage RAG pipeline
  rag.py                     # FIXED. Chunking, embedding, indexing, retrieval
  llm.py                     # FIXED. Anthropic SDK wrapper with cost tracking
  config.py                  # FIXED. Config loader with validation
  skills/
    query_classifier.md      # TUNABLE. Question classification prompt
    query_rewriter.md        # TUNABLE. Query rewriting prompt
    answer_generator.md      # TUNABLE. Answer generation prompt
    answer_validator.md      # TUNABLE. Hallucination check prompt

data/
  crag/
    dev.jsonl                # 500 stratified eval questions
    test.jsonl               # 500 held-out test questions
    documents/               # 18,752 extracted HTML documents
  vectorstore/               # LanceDB index (rebuilt from config)

scripts/
  download_crag.py           # Downloads and prepares CRAG data
  build_index.py             # Builds LanceDB vector index
  run_optimizer.sh           # Bash optimizer loop with budget tracking
  run_optimizer.ps1          # PowerShell optimizer loop with budget tracking
```

**Fixed infrastructure** (`evaluate.py`, `pipeline.py`, `rag.py`, `llm.py`) is never modified -- just like `prepare.py` in autoresearch. The optimizer only touches `config.yaml` and the four skill files in `agents/skills/`.

## Tech Stack

| Component | Technology |
|---|---|
| LLM (generation) | Claude Sonnet 4.6 |
| LLM (routing/validation) | Claude Haiku 4.5 |
| Embeddings | OpenAI text-embedding-3-small |
| Vector Store | LanceDB 0.30.0 |
| Benchmark | Meta CRAG (4,409 QA pairs, 5 domains) |
| Package Manager | uv |
| Experiment Tracking | Git + results.tsv |

## Cost

| Item | Cost |
|---|---|
| Single query (all 5 stages) | ~$0.008 |
| Full 500-question eval | ~$3.89 |
| Quick 100-question eval | ~$0.78 |
| Index build (3,720 docs) | ~$0.70 (OpenAI embeddings) |
| 18-experiment optimization run | ~$15 |

## License

MIT
