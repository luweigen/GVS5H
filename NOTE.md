# NOTE：Fable 5 / Opus-5 / GPT-5.6 / Qwen3.8 的 agent 对照分析

> 会话分析记录，2026-08-28，基于 commit `6d7a143b`。
> 表中所有分数均由本仓库 `runs/**/*.regraded.json` 重算核对过，与论文正文一致。
> 数据集统一为 LCB-100 hard（`escalation/lcb100_hardest_v6.json` 固定的 100 个 `question_id`），
> evaluator 统一为含 §3.3 `readline` 修复的版本。

---

## 1. 核心对照表

四个最常被拿来比的 arm 放在一起：

| # | Arm | pass@1 | passes | 脚手架 | 服务方 | $/pass |
|---|---|---|---|---|---|---|
| 1 | **Opus-5 + manager** | **91** | 1 | v1 | OpenRouter | 未计价 |
| 2 | **Claude Fable 5 单次** | **87.4 ± 1.1** | 5 | 无（single-call） | Anthropic 第一方 | $61.11 |
| 3 | **Qwen3.8-27B + manager** | **86.4 ± 2.7** | 5 | v2 | 本地 vLLM | $51.75 |
| 4 | **Opus-5 单次** | **85** | 1 | 无（single-call） | OpenRouter | 未计价 |

`±` 是**跨 pass 的标准差（SD）**，不是置信区间。Opus-5 只有 1 pass，因此没有离散度可报。

**读这张表必须同时读的四条限定**：

1. **1 pass vs 5 pass。** 1、4 行各只跑了一次，没有重复，无法判断是否落在噪声里。论文 §2.4 把 OpenRouter 这批单列为独立 condition，正是因为网关带来的 run-to-run 噪声。
2. **v1 vs v2 脚手架。** Opus-5 的 +6 是在**更弱的 v1** 上取得的（见 §3）。换 v2 大概率更高，但没跑。
3. **服务路径不同。** Opus-5 走 OpenRouter，Fable 5 走 Anthropic 第一方直连。论文明确指出前者是 §2.4 噪声的来源。
4. **Δ 不可跨表比。** 因为 1、4 行是 v1，3 行是 v2，"manager 带来多少提升"这个量在两套之间不严格可比（§3.1）。

**能安全下的结论**：
- Opus-5 加 manager 后的 91 是全研究最高分，高于 Fable 5 裸跑的 87.4。
- Qwen3.8-27B（27B 开源权重、本地可跑）加 manager 后的 86.4 与 Fable 5 的 87.4 差 1.0 分，
  **配对置换检验 p = 0.73，不显著**；成本 $51.75 vs $61.11。
- 这就是论文标题 "a fifth the price" 的来源 —— 不过那个"五分之一"指的是 **GPT-5.6-Terra + manager**
  （$11.71 vs $61.11），不是 Qwen3.8。

---

## 2. 总表：所有模型 × 所有条件 × 单次/+manager

一张表列全。`±` 是**跨 pass 的标准差（SD）**；只跑 1 pass 的行没有离散度。
Δ 为**逐 pass 配对差**的均值 ± SD（5-pass 行），或直接相减（1-pass 行）。
所有分数取自 `.regraded.json`（修复后的 evaluator，§7.3）。

| 模型 | 参数 | 服务方 | 条件 | 脚手架 | 单次 | +manager | Δ | 论文位置 |
|---|---|---|---|---|---|---|---|---|
| GPT-5.6-Terra | n/a | OpenAI 第一方 | 128k · ON · ×5 | **v2** | 77.0 ± 1.0 | 85.0 ± 1.0 | **+8.0 ± 0.0** | §2.1–2.3 / Fig 1–3 |
| GPT-5.6-Luna | n/a | OpenAI 第一方 | 128k · ON · ×5 | **v2** | 67.2 ± 4.3 | 77.8 ± 2.0 | **+10.6 ± 5.1** | §2.1–2.3 / Fig 1–3 |
| Qwen3.8-27B | 27B | 本地 vLLM | 128k · ON · ×5 | **v2** | 63.0 ± 4.1 ᵃ | 86.4 ± 2.7 | **+23.4 ± 6.6** | §2.1–2.3 / Fig 1–3 |
| Claude Fable 5 | n/a | Anthropic 第一方 | 128k · ON · ×5 | 无 | 87.4 ± 1.1 | — ᵇ | **—** | §2.1–2.3 / Fig 1–3 |
| Claude Opus-5 | n/a | OpenRouter | 128k · ON · ×1 | v1 | 85 | 91 | **+6** | §2.4 / Fig 4 |
| Kimi-K3 | ~2.8T | OpenRouter | 128k · ON · ×1 | v1 | 83 | 82 | **-1** | §2.4 / Fig 4 |
| Minimax-M3 | 428B | OpenRouter | 128k · ON · ×1 | v1 | 60 | 66 | **+6** | §2.4 / Fig 4 |
| Qwen3.6-35B-A3B | 35B | OpenRouter | 128k · ON · ×1 | v1 | 25 | 43 | **+18** | §2.4 / Fig 4 |
| Claude Opus-5 | n/a | OpenRouter | 128k · OFF · ×1 | v1 | *(未跑)* ᶜ | *(未跑)* ᶜ | **—** | §2.4 / Fig 6 |
| Kimi-K3 | ~2.8T | OpenRouter | 128k · OFF · ×1 | v1 | 32 | 74 | **+42** | §2.4 / Fig 6 |
| Minimax-M3 | 428B | OpenRouter | 128k · OFF · ×1 | v1 | 25 | 37 | **+12** | §2.4 / Fig 6 |
| Qwen3.6-35B-A3B | 35B | OpenRouter | 128k · OFF · ×1 | v1 | 35 | 26 | **-9** | §2.4 / Fig 6 |
| Qwen3.5-9B | 9B | OpenRouter | 128k · OFF · ×1 | v1 | 17 | 20 | **+3** | §2.4 / Fig 6 |
| Claude Opus-5 | n/a | OpenRouter | 16k · OFF · ×5 | v1 | *(未报告)* ᵈ | — | **—** | §2.4 / Fig 5 |
| Kimi-K3 | ~2.8T | OpenRouter | 16k · OFF · ×5 | v1 | 32.2 ± 4.8 | 62.6 ± 2.9 | **+30.4 ± 5.9** | §2.4 / Fig 5 |
| Minimax-M3 | 428B | OpenRouter | 16k · OFF · ×5 | v1 | 21.2 ± 1.5 | 32.2 ± 2.7 | **+11.0 ± 3.5** | §2.4 / Fig 5 |
| Qwen3.6-35B-A3B | 35B | OpenRouter | 16k · OFF · ×5 | v1 | 27.8 ± 3.9 | 26.6 ± 1.8 | **-1.2 ± 4.9** | §2.4 / Fig 5 |
| Qwen3.5-9B | 9B | OpenRouter | 16k · OFF · ×5 | v1 | 14.6 ± 0.5 | 21.8 ± 3.6 | **+7.2 ± 3.8** | §2.4 / Fig 5 |

**Claude Code 作为 agent 的那一批 —— 代码已注册，但本仓库不含任何结果：**

| 模型 | 参数 | 服务方 | 条件 | 脚手架 | 单次 | +agent | Δ | 论文位置 |
|---|---|---|---|---|---|---|---|---|
| 真 Claude (`claude-real-*`) | n/a | 订阅 OAuth | LCB 官方 harness | **Claude Code CLI** | *(无数据)* ᵍ | *(无数据)* ᵍ | **—** | 未收录 |
| Qwen3.6-27B (`claude-code-qwen3.6-vllm`) | 27B | litellm 代理 :8216 | LCB 官方 harness | **Claude Code CLI** | — ʰ | *(无数据)* ᵍ | **—** | 未收录 |

ᵃ Qwen3.8-27B 的 single 臂生成于 250k cap，此处是 **cap-match 回 128k 的重放**（§3.2），
与其 128k 原生的 manager 臂 like-for-like。按 250k 原样计分为 `65.6 ± 4.6`，Δ = `+20.8 ± 7.0`。

ᵇ Fable 5 **只跑了单次臂**，没有 manager 臂（原因见 §4）。

ᶜ Opus-5 的 `128k · OFF · ×1` 未跑：`opus_single.json` 内容是 `{"skipped": ...}`，
所以 Figure 6 只有 4 个模型。

ᵈ Opus-5 的 `16k · OFF · ×5`：p1–p3 为真实数据（67, 67, 68），**p4/p5 整批 100 题**
**`code` 全为空、`passed` 全 False** —— 是跑挂了，不是 0 分。机械平均会得到误导性的
`40.4 ± 36.9`。论文 Figure 5 只收 4 个模型（9B/35B/428B/2.8T），未报告 Opus，此处从之。

ᵉ `nem_*`（Nemotron）在 16k 条件下有占位文件，内容是 `{"note": "nemotron removed"}` ——
该模型被移除，无数据。

ᶠ `luna_single.json`（无 `_p` 后缀）是一个 56.0 的孤立旧文件，无 regraded 孪生，
非论文所用的 p1–p5，已排除。

ᵍ **这三个 arm 一次都没进过本仓库。** `lm_styles.py:69-88` 注册了 `claude-real-single`、
`claude-real-agentic`、`claude-code-qwen3.6-vllm`，`claude_code_runner.py` 也完整实现了，
但穷举检索结果为零：全仓库无任何结果文件；所有 `runs/*/results/*.json` 的 `model` 字段
只出现 9 个值（见下），没有一个是 Claude Code 路径；`runs/*/ws/` 的子目录只有
`{kimi,mm3,q35,q9,opus,luna,terra,q38,fable5}_{single,multiagent}[_pN]`；
`git log --all --name-only | grep -i claude` 在**全部历史**中只返回三个 `.py` 源文件，
没有任何数据路径。README §5 说明原因：`LiveCodeBench/output/` 与 `claude_transcripts/`
（~177 MB）属于**另一个实验**，与本论文不共享数据，打包时排除。

仓库中出现过的全部 9 个 `model` 值：
```
anthropic:claude-fable-5          openrouter:anthropic/claude-opus-5
openai:gpt-5.6-terra              openrouter:moonshotai/kimi-k3
openai:gpt-5.6-luna               openrouter:minimax/minimax-m3
groq:small-model  (= Qwen3.8-27B) openrouter:qwen/qwen3.6-35b-a3b
                                  openrouter:qwen/qwen3.5-9b
```

ʰ `claude-code-qwen3.6-vllm` 只注册了 agent 形态（`LCB_CLAUDE_MODE` 默认 `agentic`）；
它的"单次"对照位由 `qwen3.6-27b-vllm`（`LMStyle.OpenAIChat`，直连同一个 litellm 代理）承担，
同样无结果数据。另注：`LCB_CLAUDE_MODEL` 若不设，真 Claude 那条路默认 `sonnet`。

### 读表要点

1. **上四行（v2，5-pass，pinned backend）是唯一互相严格可比的一组**，也是论文的主结果。
   其余全是 v1 + OpenRouter，与之**既不同脚手架也不同服务路径**（§3）。
2. **manager 不是稳赢**：Kimi-K3 在 128k·ON 下 −1，Qwen3.6-35B 在 128k·OFF 下 −9、
   在 16k·OFF 下 −1.2。三次负 Δ 全部出现在 v1 上。
3. **reasoning 关掉时 Δ 最大**：Kimi-K3 32→74（+42）。低预算/无思考时脚手架的
   救援价值最高；模型本身越强、预算越宽，Δ 越小。这正是论文的核心论点。
4. **16k 条件下的 Δ 大量来自"能否吐出代码"**，而非推理质量（§7.4）。

### 逐 pass 原始值（5-pass 条件）

```
terra_single       [78, 77, 78, 76, 76]   → 77.0
terra_multiagent   [86, 85, 86, 84, 84]   → 85.0
luna_single        [61, 69, 65, 72, 69]   → 67.2
luna_multiagent    [78, 76, 78, 76, 81]   → 77.8
q38_single.cap128k [68, 66, 59, 63, 59]   → 63.0
q38_single (250k)  [71, 69, 60, 66, 62]   → 65.6
q38_multiagent     [83, 86, 88, 85, 90]   → 86.4
fable5_single      [86, 87, 87, 88, 89]   → 87.4
kimi_single        [26, 30, 34, 39, 32]   → 32.2   (16k/OFF)
kimi_multiagent    [64, 61, 67, 61, 60]   → 62.6   (16k/OFF)
mm3_single         [21, 19, 23, 21, 22]   → 21.2   (16k/OFF)
mm3_multiagent     [35, 31, 29, 35, 31]   → 32.2   (16k/OFF)
q35_single         [29, 23, 33, 25, 29]   → 27.8   (16k/OFF)
q35_multiagent     [29, 27, 24, 26, 27]   → 26.6   (16k/OFF)
q9_single          [15, 14, 15, 14, 15]   → 14.6   (16k/OFF)
q9_multiagent      [22, 22, 26, 23, 16]   → 21.8   (16k/OFF)
opus_single        [67, 67, 68, ✗, ✗]     → 未报告 (16k/OFF, 见 ᵈ)
```

### 成本（§2.2，Table 3；仅覆盖 §2.1 的第一方 arm，§2.4 未计价）

| Arm | 费率 $/MTok in/out | In (MTok) | Out (MTok) | $/pass | $/solved |
|---|---|---|---|---|---|
| Qwen3.8-27B single | 0.35 / 2.75 | 0.0753 | 7.4247 | $20.44 | $0.32 |
| Qwen3.8-27B manager | 0.35 / 2.75 | 1.5053 | 18.6277 | $51.75 | $0.60 |
| GPT-5.6-Luna single | 0.20 / 1.20 | 0.0661 | 0.3299 | $0.41 | $0.006 |
| GPT-5.6-Luna manager | 0.20 / 1.20 | 1.1686 | 1.0522 | $1.50 | $0.019 |
| GPT-5.6-Terra single | 2 / 12 | 0.0661 | 0.2728 | $3.41 | $0.044 |
| GPT-5.6-Terra manager | 2 / 12 | 1.1098 | 0.7911 | $11.71 | $0.14 |
| Fable 5 single | 10 / 50 | 0.0899 | 1.2043 | $61.11 | $0.70 |

最便宜到最贵跨度 149×（Luna single $0.41 → Fable 5 single $61.11），换来 +20.2 分。
重试并丢弃的调用**计入**成本 —— 它们确实生成了、确实会计费。

---

## 3. 两套脚手架：v1 vs v2

| | v1 (`codebase/v1-be9dfa2/`) | v2 (`codebase/v2-current/`) |
|---|---|---|
| 轮数预算 `MULTIAGENT_MAX_ITERS` | 4 | 10 |
| sample-test verifier（§3.1 step 5） | 无 | 有 |
| cut-off summarizer | 无 | 有 |
| workspace 文件大小上限 | 无 | 有 |
| 题目选择 | 运行时取最新 100 hard（`--lcb 100`） | 固定 id 列表（`lcb100_hardest_v6.json`） |
| 产出 | §2.4 OpenRouter 那批（含 **Opus-5**） | §2.1–§2.3 七个第一方 arm |

四处差异**全部只作用于 manager 臂**，single 臂在两版下都是一次调用。
因此 **manager − single 的 Δ 在两套之间不严格可比**，这也是论文把 §2.4 单列而不并入 §2.1 的原因。

两处论文未列举但值得知道的差异：
- **题目选择**：两者解析到同一批 100 题，但 v2 的固定 id 文件让它可复现而非依赖运行日期。
- **一处 post-paper 修复只在 v2**：`orchestrator.py` 现在拿疑似 provider clamp 与**实际发出的 cap**
  比对，而非配置的 cap。写在跑完之后，未影响任何已报数据。

脚手架本身：manager–worker + 共享 workspace 的 ledger 结构，零训练、零任务微调，manager 是固定 prompt。
每题一个 workspace，内含 `task.md` / `plan.md` / `tasks.json` / `notes.md` / `solution.py` / `transcript.jsonl`。

---

## 4. Fable 5 为什么没有 manager 臂

**Fable 5 是纯单次调用跑的，没有用任何 agent。**

- 代码路径：`run_bench.py --engine single` → `multiagent.py:622` 的 `single_solve()`。
  一次 `_chat()`，system prompt + 题面，**无工具、无循环**，ledger 那套（`plan.md`/`tasks.json`/`notes.md`）完全不参与。
- 驱动脚本 `run_fable5_5pass_single.sh` 的注释写明理由：
  *"WHY SINGLE-ONLY. No manager arm here, so this run measures the model, not the scaffold."*
- 论文 §4.5 明确把这列为局限之一：**"Fable 5 has no manager arm."** 它是**参考臂（reference arm）**。

该脚本记录的三条 Fable 5 特有条件：

1. **thinking 关不掉、也没有 budget。** `{type:disabled}` 和 `{type:enabled,budget_tokens:N}` 都返回 400；
   实际发的是 `{type:adaptive, display:summarized}`。所以这条臂**不可避免地 reasoning-ON**，
   且 `meta["reasoning"]` 是**摘要**而非原始思维链（transcript 里带 `reasoning_is_summary` 标记，
   与返回真实 CoT 的两个 Qwen 臂区分开）。深度用 `output_config.effort`，钉在 `high`。
2. **128k 是模型硬上限**，不是选择。且该 cap **同时约束 thinking + answer**：
   一道题若思考满 128k 就返回不了代码，记为 `truncated` —— 这是诚实的结果，不能靠提高 cap "修掉"。
3. **拒答被计为失败，不重试、不 fallback。** Fable 5 的分类器可能 decline（HTTP 200，`stop_reason=refusal`）。
   Anthropic 的建议是传 `fallbacks` 让别的模型接管，此处**故意不做** ——
   "a benchmark cell labelled Fable 5 must contain Fable 5's outcome"。
   拒答落为 `empty_stop` + `finish_reason=refusal`。

**Fable 5 的 9 个空输出里有 6 个是拒答**（§2.3）。六次拒答落在**三道普通的竞赛题**上，
都不涉及安全或生物相关内容，且**不确定性的** —— 题 3739 在五次中被拒三次、3682 两次、abc393_e 一次。
代价约 **1.2 分**。论文自己说这让针对 Fable 5 的比较 "mildly conservative in its disfavour"
—— 即对 Fable 5 略微不利。

---

## 5. `LiveCodeBench/claude_transcripts/` 那个独立实验

**结论：代码在仓库里，结果不在。**

- `git log --all -- "*claude_transcripts*" "*LiveCodeBench/output*"` → **空**。
  这些路径从未被 commit，是打包时就排除的（README §5：~177 MB，与本论文不共享任何数据）。
- 全仓库找不到 `claude-real-single` / `claude-real-agentic` / `claude-code-qwen3.6-vllm` 的任何结果文件。
- 论文正文**完全没提**这个实验。§4.5 的 "run but not reported" 只说了 AIME/MATH-500/GPQA/HLE
  （前沿模型接近天花板，Opus-5 在 AIME/GPQA/MATH-500 上 100%，没有测量空间）。

### 代码显示它打算测什么

`codebase/livecodebench/lcb_runner/runner/claude_code_runner.py` 把 `claude -p` 整个包成
LCB 眼里的一个 "LLM"（`LMStyle.ClaudeCode`）。`lm_styles.py:69-88` 注册了三个 arm：

| model id | 含义 |
|---|---|
| `claude-code-qwen3.6-vllm` | `claude -p` agent，后端换成本地 Qwen3.6-27B（litellm 代理 `localhost:8216`） |
| `claude-real-single` | 真 Claude，`--tools ''`，单轮 |
| `claude-real-agentic` | 真 Claude，带 Read/Write/Edit/Bash/Glob/Grep，多轮 |

即一个 **2×2 设计**：{真 Claude, 本地 Qwen} × {单轮, agentic}，
用来拆开"agent 脚手架的贡献"与"模型本身的贡献" —— 和论文 manager-vs-single 同一思路，
只是脚手架换成 Claude Code CLI 本身。

两种模式交付方式不同（`_invoke_once`）：
- **agentic**：给临时工作目录 + `--permission-mode bypassPermissions`，`AGENTIC_CONTRACT` 要求
  跑通所有样例、自己造边界用例、必要时写 brute-force 做 stress test，最后把答案写进 `solution.py`
  —— harness 读文件，不读对话。
- **single**：`SINGLE_CONTRACT` 要求单个 ```python 块，从 stream-json 最后的 `type=="result"` 事件提取。

几个说明它真跑过的工程细节：
- `usage_guard()`：真 Claude 走订阅 OAuth（`~/.claude/.credentials.json`），跑前轮询
  `api.anthropic.com/api/oauth/usage`，任一窗口用量 ≥90% 就 sleep 到 reset。
  专门处理了"轮询自己被 429"：不盲目放行，复用上一次成功读数。
- 900s wall clock 超时，超时也照样落 transcript。
- prompt 走 **stdin** 而非位置参数 —— `--tools` 是变长 flag，会把题面吞成工具名。
- `LOG_DIR = "claude_transcripts"`，每题一个 `<md5前12位>.jsonl`，首行 meta 后接 stream-json 逐行事件。

### 别混淆的另一条 `claude -p` 路径

`codebase/v2-current/escalation/orchestrator.py:340` 的 `claude_cli_chat()` —— 模型串写成
`claude:<name>` 时走订阅 auth 而非 API key。注释明确说它 *"NOT equivalent to the HTTP paths above,
and deliberately so"*（CLI 不暴露 thinking 文本，只能记录*发生过* thinking）。
**论文报的 Fable 5 那条臂没有走它**，走的是第一方 `anthropic.Anthropic` streaming（`orchestrator.py:441`）。

---

## 6. 外部检索结果

### 6.1 作者的其他论文：找不到

作者：Victor Gao、Vida Khosrowshahi、Ali Khosrowshahi、Xihao Sun、Juhyun Lee、
Simon (Sang Won) Lee，单位 **Persis Capital Inc.**，通讯 `slee@persisholdings.com`。

- 精确标题检索、作者名 + Persis 组合检索、arXiv 检索 —— **零命中**。
- 搜到的同名人是不同人：Sang Won Lee 是 Virginia Tech 的 HCI 教授，Victor Gao 是外交界人士。
- 合理解释：论文日期 2026-08-25，尚未上 arXiv 或未被索引。

**没有同团队前作可作纵向对照。**

### 6.2 第三方的 "Claude Code agent 跑 LiveCodeBench" 分数：不存在

这是搜下来最确定的一条负面结论。生态里的分工很清楚：

- **LCB 被当作"裸模型算法能力"榜**，跑法是 zero-shot 单次调用、无工具。
- **agent 评测走另一条线**：Artificial Analysis 的 Coding Agent Index 有
  `Claude Code - Opus 5 (max)` 67.0% / `(high)` 65.6%，但那是
  DeepSWE + Terminal-Bench v2.1 + SWE-Atlas-QnA 的合成分，**不含 LCB**。
  HAL (Princeton) 的 Claude Code agent 页同理，覆盖 SWE-bench 那一系。
- 有论文提到"同一模型换 harness 能摆动 30–50 个百分点"，说明大家意识到 scaffold 影响巨大，
  但**没人在 LCB 上做这个 ablation**。

### 6.3 外部榜单数字（低可信度，未能核实）

搜索摘要给出的 LCB 榜：Fable 5 89.78% / Opus 5 89.03% / Gemini 3.1 Pro 88.48% /
Gemini 3.6 Flash 88.08% / GPT-5.2 Codex 87.99%。

**两条限制，请勿直接引用**：

1. **网络被 egress proxy 挡住**：`vals.ai`、`arxiv.org`、`livecodebench.github.io`、
   `hal.cs.princeton.edu`、`contracollective`、`benchlm` 全部 `EGRESS_BLOCKED`；
   `curl` 探测除 github 外全部超时。以上数字**只来自搜索引擎摘要，原始页面未能打开核实**。
2. **摘要自相矛盾**：同一轮搜索里，一条说 "Fable 5 89.78% / Opus 5 89.03%"，
   另一条说 "Opus 5 解出约四成 hard，Fable 5 三成，九分差距"。两者不可能同时成立。

即便数字为真，也与本论文**不可比**：全难度混合 vs 100 hardest、官方 evaluator vs
修过 `readline` bug 的 evaluator、单次调用 vs 五次取 pass@1。

---

## 7. 方法学注意事项

### 7.1 `±` 的含义：Table 1 是 SD，图里是 CI

- **Table 1（正文表）**：`Mean ± standard deviation (SD) across passes`，表题写明。
- **各 Figure 的误差棒**：95% CI（t, df=4），由 `pass_ci()` 计算
  = `mean ± t.ppf(0.975, n-1) * std(ddof=1) / sqrt(n)`。

两者差约 1.24 倍。例：Terra single 逐 pass `[78,77,78,76,76]` → SD = **1.0**（表），CI 半宽 = **1.2**（图）。
Terra 的 `Δ = +8.0 ± 0.0` 也是 SD，五次 Δ 全为 +8。

引用时务必说清是哪一个。

### 7.2 三个后缀，论文报的是最后一个

- `<name>.json` —— 生成时按当时 evaluator 计分。
- `<name>.cap128k.json` —— 仅 Qwen3.8 single 臂：同一批生成截断到 128k 输出后重新抽取解（§3.2）。
- `<name>.regraded.json` —— 在**修复后的 evaluator** 上重新计分（§3.3）。
  每条记录保留 `passed_before_regrade`，文件保留 `pass@1_before_regrade`，修正可审计。

**论文每张图表读的都是 `.regraded.json`**，Qwen3.8 single 臂读 `.cap128k.regraded.json`。

### 7.3 §3.3 的 evaluator bug

上游 stdin mock 把 `MockBuffer.readline()` 实现成无状态表达式，每次调用都返回第 1 行。
任何通过 `sys.stdin.buffer.readline()` 读多行输入的解，无论多正确都会被判错。
见 `lcb_runner/evaluation/testing_util.py`。**论文所有数字都是修复后报的。**

另有一张容易与之混淆的表（§2.3）：**"限定在真正吐出代码的 problem-pass 上"**的重算，
它衡量的是空输出的拖累，不是 regrade 前后：

| 模型（single 臂） | 如实计分 | 吐出代码 | 仅限这些 |
|---|---|---|---|
| GPT-5.6-Terra | 77.0 | 500/500 | 77.0 |
| GPT-5.6-Luna | 67.2 | 500/500 | 67.2 |
| Qwen3.8-27B | 63.0 | 465/500 | 67.7 (+4.7) |
| Claude Fable 5 | 87.4 | 491/500 | 89.0 (+1.6) |

即：若不计那 9 个空输出，Fable 5 是 89.0；论文报的 87.4 是把空输出计为失败的诚实口径。

### 7.4 Δ 里有多少是"救回截断"

`Δ` 部分跟踪的是"能否吐出代码"，不全是"想得更对"：

- 非空完成数 single→manager：Qwen3.6-35B 34→68、Minimax-M3 92→93、Kimi-K3 97→100、**Opus-5 97→100**。
- 128k cap 下 500 个 problem-pass 的截断/空输出（single/manager）：
  Terra 0/0、Luna 0/0、Qwen3.8 **150/5** 与 **35/0**、Fable 5 3/− 与 9/−（其中 6 个是拒答）。
- **两个 OpenAI 臂在全部 2,000 个 problem-pass 上零截断、零空输出** ——
  所以它们在 §2.1 的 Δ **完全不含救援成分**，是最干净的脚手架效应证据。

但也不全是救援。§4.3 有个干净的纠错案例（**Opus-5**，LCB `abc388_e`）：
单次调用的可行性判定 over-count（报 225 对，最优 220）；manager 臂先把交换论证写进 `notes.md`
（K 个最小元素作 top、按序匹配 K 个最大元素作 bottom 为最优；可行性对 K 单调，据此可二分），
再让一个 worker 实现、第二个 worker 加固。这是真纠错，不是截断救援。

另一个（Qwen3.8）：推理**已经想到正确思路**（在讨论最小割形式化）却来不及写下来；
manager 臂把同一归约作为 plan 提交到 `plan.md` 再让 worker 实现，五次全胜。
论文的总结很到位：**脚手架的作用不是提供洞见，而是逼它在预算耗尽前落到磁盘上。**

### 7.5 元数据小坑

`q38_*` 文件的 `model` 字段记的是 `groq:small-model`，而论文写的是 local vLLM。
这是 `orchestrator.py` 环境驱动路由留下的标签（OpenAI 兼容客户端指向本地 vLLM），不影响分数。
若要拿这些 JSON 的 metadata 做 provenance 追踪，别被前缀误导。

---

## 8. 待办 / 下一步

### 已就绪：订阅制跑 Claude Code 两臂

脚本：**`codebase/v2-current/escalation/run_bench_script/run_claudecode_sub_5pass.sh`**

```bash
N=5 PASSES=1 ARMS=single ./run_claudecode_sub_5pass.sh    # 冒烟，先验证链路
CC_MODEL=opus ./run_claudecode_sub_5pass.sh               # 完整 5 pass × {single, manager}
```

**为什么这条路可比性最好**：走 `MULTIAGENT_MODEL="claude:<alias>"` →
`orchestrator.claude_cli_chat()` → `claude -p --tools "" --model <alias>`，
用的是**订阅 auth，不需要 API key**；同时复用 `run_bench.py`、同一份
`lcb100_hardest_v6.json`、同一套 v2 脚手架参数（`MAX_ITERS=10`、`MAX_TASKS=12`）、
同一个 code extraction 与修复后的 evaluator。产出的两个数可以直接填进 §2 总表的
Single / Manager 两列。

**三条不可比之处（CLI 强制，非选择）**，必须随数字一起标注：

1. **输出 cap 不可控。** `claude -p` 不暴露 `max_tokens`，`ESCALATION_CLOUD_MAX_TOKENS`
   在这条路上**无效**（见 `claude_cli_chat` docstring）。§2.1 其余各臂都钉在 128k，
   这条不是。**这是最大的缺口 —— 不要把它放进"128k cap"那一列而不加脚注。**
2. **thinking 既不可开关也不可读。** 此传输层无 reasoning 旋钮；CLI 返回的 thinking block
   文本为空、只有 signature，所以只能记录 `meta.thinking_blocks`（想了几块），
   记不到想了什么 —— 比 Fable 5 / Opus-5 的"摘要"还弱一档。
3. **temperature 不适用。** 其余各臂 0.2；CLI 不接受该参数。

**脚本内置的四道闸**（都是实测出来的坑）：

- **`ANTHROPIC_API_KEY` 会被主动 unset。** 环境里存在这个 key 时，CLI 会转为 **API 计费**
  而不是订阅 —— 与本脚本的目的正好相反。同时清掉 `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_BASE_URL`。
- **`n_infra` 检查，而不只是 id 检查。** `run_bench.py` 把 infra 失败的记录**保留在
  `records` 里**、但从 pass@1 的分母中剔除（`run_bench.py:176-186`）。所以配额被限流时，
  100 个 id 一个不少、id 检查照样通过，而 pass@1 其实是在更少的题上算的 ——
  **一个静默错误的分母**。脚本查 `n_infra`，非零即报警并要求重跑该 pass。
- **崩溃残留文件不会被当成"已完成"跳过。** 失败的 pass 会留下
  `{"engine":..,"model":..}` 且无 `lcb` 键的残file；脚本对每个已存在的输出先跑 `check()`，
  验不过就删掉重跑，并在结尾以非零退出码汇报失败数。
- **`LiveCodeBench` 符号链接自举**（见下）。

### 本包的一个打包 bug：`LiveCodeBench` 路径对不上

`run_bench.py:16-19`、`regrade.py:21`、`capmatch_q38.py:31` 都做
`sys.path.insert(0, <escalation 的父目录>/LiveCodeBench)`，
但本包把 harness 放在 `codebase/livecodebench/`（**小写、且高一层**）。
Linux 下大小写敏感 —— **README §4 里的每一条复现命令都会当场 `ImportError: lcb_runner`。**

一行修复（脚本已自动做，幂等）：

```bash
ln -s ../livecodebench codebase/v2-current/LiveCodeBench
```

v1 若也要跑，同样需要 `ln -s ../livecodebench codebase/v1-be9dfa2/LiveCodeBench`。

### 仍然待办

**要补的那个格子：Claude Code (CLI agent) on LCB-100 hard。**

`claude_code_runner.py` 就是干这个的，且跑的是**同一份修过 evaluator 的 harness**
（`codebase/livecodebench/`），所以 §3.3 的修复自动生效。两个 arm 直接对上现有的表：

```bash
LCB_CLAUDE_REAL=1 LCB_CLAUDE_MODE=single  LCB_CLAUDE_MODEL=<model> \
  python -m lcb_runner.runner.main --model claude-real-single  --release_version release_v6 ...
LCB_CLAUDE_REAL=1 LCB_CLAUDE_MODE=agentic LCB_CLAUDE_MODEL=<model> \
  python -m lcb_runner.runner.main --model claude-real-agentic --release_version release_v6 ...
```

注意上面那个脚本测的**不是** Claude Code 自己的 agent loop：`claude_cli_chat()` 用
`--tools ""` 把 CLI 当成一个单轮补全通道，agent 那一层由**论文自己的 v2 manager 脚手架**提供。
这正是可比性最好的组合 —— 它填的是"Anthropic 模型 + 论文脚手架"这个格子。

**想测 CLI 自带的 agent loop 则是另一件事**，阻塞点也不同：那要走
`claude_code_runner.py` + LCB 官方 runner，而官方 runner **没有 `--ids-file`**
（`run_bench.py:130-132` 的固定 id 逻辑是 escalation 独有的）。不把题目集对齐，
数字无法与 85→91 / 87.4 / 86.4 直接比。要补就得给官方 runner 打一个 `--ids-file` 补丁。

两条路测的是不同的东西，别混为一谈：
| | 脚本 | agent 层来自 | 可直接填进 §2 总表？ |
|---|---|---|---|
| A（已就绪） | `run_claudecode_sub_5pass.sh` | 论文 v2 manager 脚手架 | **可以**（加 cap 脚注） |
| B（待打补丁） | `claude_code_runner.py` | Claude Code CLI 自身 | 需先对齐题目集 |

**其他可补的**：
- Opus-5 在 **v2** 脚手架上重跑，并做 5 pass —— 现有的 85→91 是 v1 + 1 pass，是全表最弱的证据。
- Fable 5 的 manager 臂。论文 §4.5 自己承认：它是 *"the strongest single-call result in the paper
  is also the one condition where we cannot say what the scaffold would do."*

---

## 附：关键文件索引

| 内容 | 路径 |
|---|---|
| 单次调用实现 | `codebase/v2-current/escalation/multiagent.py:622` (`single_solve`) |
| Fable 5 驱动脚本 | `codebase/v2-current/escalation/run_bench_script/run_fable5_5pass_single.sh` |
| 第一方三臂驱动脚本 | `.../run_bench_script/run_4models_1pass_reason_on.sh` |
| provider 路由 / `claude:` 前缀 | `codebase/v2-current/escalation/orchestrator.py:340, 441, 498` |
| Claude Code CLI 包装（独立实验） | `codebase/livecodebench/lcb_runner/runner/claude_code_runner.py` |
| CLI arm 模型注册 | `codebase/livecodebench/lcb_runner/lm_styles.py:69-88` |
| evaluator 修复位置 | `codebase/livecodebench/lcb_runner/evaluation/testing_util.py` |
| 重新计分工具 | `codebase/v2-current/escalation/regrade.py` |
| cap-match 重放工具 | `codebase/v2-current/escalation/capmatch_q38.py` |
| CI 计算 | `.../run_bench_script/plot_16k_reason_off_5_pass.py:222` (`pass_ci`) |
| 固定题目 id | `codebase/v2-current/escalation/lcb100_hardest_v6.json` |
