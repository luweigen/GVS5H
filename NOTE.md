# NOTE

本文件由两份独立的会话记录合并而成，两者主题不同，内容均按原样保留：

| | 主题 | 出处分支 |
|---|---|---|
| **第一部分** | 多 Agent 的分工与协作机制 —— 脚手架怎么运转 | `claude/multi-agent-division-collaboration-iv9jqt` |
| **第二部分** | Fable 5 / Opus-5 / GPT-5.6 / Qwen3.8 的 agent 对照分析 —— 跑出来什么、还差什么 | `claude/qwen-fable5-agent-comparison-qssqbl` |

两部分各自独立编号（第一部分 §1–§10，第二部分 §1–§8），互相引用时请带上"第一部分/第二部分"前缀。
第二部分末尾的「关键文件索引」覆盖整个仓库，对两部分都适用。

---
---

# 第一部分：多 Agent 的分工与协作机制


本文说明这套 manager–worker 脚手架里"多个 agent 如何分工、如何协作"。

**代码位置**:`codebase/v2-current/escalation/multiagent.py`(643 行,下文行号均指此文件);
v1 对照版在 `codebase/v1-be9dfa2/escalation/multiagent.py`。
**论文对应**:§2「Our experiment」是它的文字版,§3.1 列出 v1→v2 的四项差异。

---

## 1. 前提:所有 agent 是同一个模型

论文的定义:**agent = 一次带独立角色、全新上下文的模型调用**。没有异构模型、没有训练、
没有针对 benchmark 的调优——这叫 *zero-shot self-orchestration*。

所以"分工"完全由 **system prompt + 喂给它什么上下文** 造出来,而不是由能力差异造出来。
`MODEL`(`:41`)是单一环境变量,manager 和 worker 用的是同一个权重。

---

## 2. 分工:六个角色

| 角色 | 函数 | 职责 | 关键约束 |
|---|---|---|---|
| **manager(开局)** | `_primary_plan` `:224` | 写 3–6 句总纲 `plan.md` + 3–6 条初始任务 | 输出截到 `MAX_PLAN_CHARS=4000`(`:197`),因为 plan 会注入之后**每一次**调用 |
| **ideation worker** | `_ideation_worker` `:254` | 只"想":找核心难点、列**几条互不相同**的候选算法/数据结构/归约,各自的坑 | 明令禁止写代码,并用 `_strip_code`(`:137`)强行剥掉代码块 |
| **manager(每轮)** | `_primary_manage` `:287` | 复盘当前解 + 上一个 worker 的结果 → 重排任务表(合并 / 标 done / 只吸收真正新的提案)→ 判 `done`/`continue` 并**只指定一条**下一个任务 | 温度 0.2;prompt 里有"卡住就换路线,别磨同一个想法" |
| **worker** | `_worker` `:371` | 干那一条任务:产出**完整自包含**的 `solution.py`,**重写** `notes.md`,报 NEXT/STATUS | 温度 0.2;"若任务是换路线,就重写一份新解,别打补丁" |
| **cutoff summarizer** | `_summarize_cutoff` `:353` | worker 撞 token 上限被截断时,单独一次廉价调用把半截思路压成 3–5 句 | 明令"不许自己把解写完" |
| **finalize worker** | `_worker(..., finalize=True)` `:595` | 输出最终交付物 | 仅当 manager 没签收可用答案时才跑(`:592`),避免冗余 finalize 把已正确的答案冲掉 |

### 信息流是刻意不对称的

```
                 ┌──────────────── manager ────────────────┐
   看得到:  problem · plan.md · notes.md · solution.py · 任务表 · 上轮 summary
   看不到:  worker 的原始输出(只拿到一句 summary,:466)

                 ┌──────────────── worker ─────────────────┐
   看得到:  problem · plan.md · notes.md · solution.py · 一条任务
   看不到:  任务表全貌、别的 worker 的存在、之前几轮的对话
```

这就是论文 §1 说的"短 worker 调用 + 共享笔记"降低上下文压力的来源:
没有任何一个 context window 需要装下整个求解过程。

---

## 3. 协作介质:共享文件系统 ledger,不是消息传递

没有 agent-to-agent 通信,也没有共享 context。**唯一的协作面是磁盘上的真实文件**
(docstring `:15-28`)。workspace 目录名 = `md5(problem_text)[:12]`(`_slug` `:78`):

| 文件 | 写者 | 读者 |
|---|---|---|
| `task.md` | 框架(一次) | — |
| `plan.md` | manager 开局 | 每个后续 prompt |
| `notes.md` | ideation 播种,之后每个 worker **整份重写** | manager + 每个 worker |
| `solution.py` / `answer.md` | worker | manager + 每个 worker + 评分器 |
| `tasks.json` | 每轮 manager 之后 | **无人读回**(纯 debug 快照) |
| `transcript.jsonl` | 每次调用 | 无角色读(事后分析用) |

两个容易看漏的点:

- **`tasks.json` 是死的**。活的任务表是内存变量 `tasks`,在循环里传递、每轮重新渲染进
  manager 的 prompt。`id` 每次整理都从 1 重编,`result` 永远是空串。
- **`notes.md` 是"重写"而不是"追加"**(`:437-450`)。worker 拿到当前 notes,交回一份
  **替换版**,过时内容被删掉。代码注释记了原因:append-only 增长曾把 manager 的 prompt
  推到 ~91k tokens 撞 131k 窗口,调用直接失败(2026-08-12 muse 那次,8 题 26 次调用耗尽)。
  而且**被截断回复的 NOTES 直接丢弃**——半截的既不能拿来替换整份,追加又会重新引入无界增长。

---

## 4. 控制流(`multiagent_solve` `:526`)

```
清空 workspace  (:540)
  │  同题重跑必须 clean-slate,否则上轮的 solution.py 会被当成"当前解"原样返回
  ▼
_primary_plan          → plan.md + 初始任务表                      [1 次调用]
  ▼
_ideation_worker       → notes.md 播种 + 若干候选路线              [1 次调用]
  ▼
_primary_manage        → 合成任务表,挑第一条任务                  [1 次调用]
  ▼
while status=="continue" and next_desc and iters < MAX_ITERS(=10):   # :557
  ├─ _worker(那一条任务)      → 写 solution.py / 重写 notes.md   [1 次调用]
  │    └─(若被截断)_summarize_cutoff                            [+1 次调用]
  ├─ _run_samples(仅当这轮真写了代码)  → 跑公开样例             [无模型调用]
  └─ _primary_manage(summary 前面拼上样例判决) → 新状态 + 下一条任务 [1 次调用]
  ▼
finalize worker(仅当 manager 没签收)                             [0 或 1 次调用]
```

关键在于**没有固定流水线**:manager 每一轮自己决定还有没有下一步、下一步是什么
(论文 §2「A manager that adapts the plan」)。

---

## 5. 反馈闭环:样例测试是 v2 的分水岭

`_run_samples`(`:473`)把 `solution.py` 拿去跑题目的 **public stdin 样例**,
`_sample_feedback`(`:510`)把结果变成一句 manager 能消费的话,拼在 summary 最前面。
配套两道闸:

- **prompt 级**:manager 的 system prompt 明说"样例判决是 ground truth,FAILED 就**必须**
  continue"(`:305-308`)。
- **代码级硬闸**(`:583-587`):即使 manager 说 `done`,只要样例没全过就强行改回 `continue`。

两个踩过的坑写在注释里:

1. 必须用 `sys.executable` 而不是裸 `python3`——否则 numpy 解法全判失败,manager 会烧完
   10 轮去修本来就对的代码。
2. 只在**这一轮真的写了代码**时才评测,否则是在拿上一轮的解糊弄 manager。

---

## 6. 防崩溃机制

| 机制 | 位置 | 作用 |
|---|---|---|
| 无进展守卫 | `:561-563` | manager 把刚发过的任务原样再发一次 → 判无进展,立即停,不浪费整次生成 |
| 不变量:无解不许 done | `:337` | 还没产出任何解就不能宣告完成 |
| 不变量:无解无任务 → 强制实现 | `:344-348` | 塞一条"把最有希望的路线实现出来" |
| 写盘上限 | `:194` `:197` `:72` `:189` | plan 4000 / notes 8000 / 答案 20000 字符,任务表 12 条 |
| 格式健壮性 | `_sections` `:143` | 接受 `### H`、`**H**`、`H:` 三种 header 写法 |
| 严格格式开关 | `STRICT_FORMAT` `:56` | 针对会无视角色直接解题的模型追加硬指令;**按 arm 开关**,保证其他模型的 prompt 与已发表 run 逐字节一致 |
| 可审计性 | `_chat` `:107` | 每次调用连同 reasoning、被丢弃的重试、token 数全量落盘;`reasoning_is_summary` 标记区分 Anthropic 的思考摘要与 vLLM 的真链 |
| 基建失败标记 | `:611-614` | 产出为空且网关耗尽 → `infra_fail`,评分器剔除而非算作答错 |

尺寸上限不是洁癖:注释记了没有上限时的后果——截断的 plan 调用解析不出 section,
fallback 把整份 ~128k token 的 dump 写进 `plan.md`(实测 205KB / 483KB 两例),
之后每次调用都溢出窗口,全程零代码产出。

---

## 7. v1 与 v2 的差别(全部只作用在 manager 一侧)

| | v1 | v2 |
|---|---|---|
| 轮次预算 `MULTIAGENT_MAX_ITERS` | 4 | 10 |
| 样例验证器 | 无 | 有 |
| 截断摘要 agent | 无 | 有 |
| workspace 文件尺寸上限 | 无 | 有 |
| ideation 代码剥离 `_strip_code` | 无 | 有 |

v1 的 manager 是"盲眼"的——只能靠读代码猜对错。v2 加的那个 pass/fail 信号,
正是让"多给轮次 + 换路线"这条规则真正生效的东西。

**基线对照**:`single_solve`(`:622`)是同一模型的一次裸调用,同样落 transcript,
用于计算 manager − single 的配对差值。

---

## 8. 真实轨迹

`transcript.jsonl` 因体积(~1.4 GB)被 `.gitignore` 排除,但 ledger 文件本身入库了——
那正是各角色实际读写的东西。以下两例取自
`runs/firstparty-128k-reasoning-on-5pass/ws/q38_multiagent_p1/`(Qwen3.8-27B,pass 1)。

### 例一:`abc384_g` — ws `6845ae76b1c5`,5 次调用

计划与实做分叉的典型。

**`plan.md`(manager 开局)**提出:sqrt 分块 + **wavelet tree / 持久化线段树**处理部分块。

**`tasks.json` 第 1 条(几轮之后)**却是:

> Select approach: adaptive index sqrt decomposition with on-the-fly prefix columns and
> hybrid partial-partial handling (**no stored N x M tables**).

也就是说 wavelet tree 被推翻了,换成按需计算的前缀列。`notes.md` 最终沉淀出完整的
块模型、四段分解 `F_A×F_B + F_A×R_B + R_A×F_B + R_A×R_B`、复杂度与边界条件。
manager 的计划是起点,不是契约——这正是"no fixed pipeline"的含义。

结果:manager 与 single 都通过。

### 例二:`3701`(LeetCode good caption)— ws `705161ed586e`,18 次调用

**manager 赢、单次调用输**的典型,也是全 pass 里循环最长的几题之一。

| | manager | single |
|---|---|---|
| `passed` | ✅ True | ❌ False |
| `finish_reason` | `stop` | **`length`** |
| 调用次数 | 18(其中 1 次被截断 → 触发 cutoff summarizer) | 1 |
| completion tokens | — | 250,000(撞顶) |

单次调用在 25 万 token 处被硬切断,交不出完整程序。manager 把同样的工作拆成 ~7 轮短调用,
每轮各自远离上限,只有一次撞顶且被摘要 agent 接住了。

从 ledger 能读出协作痕迹:

- `plan.md` 提的是"按位置和当前 run 字符做后缀 DP `G[i][c]`";
- `notes.md` 最终落到 **79 状态的 run-length 自动机 DP**(state 0 为起点,
  `1+3c / 2+3c / 3+3c` 表示当前 run 长度 1 / 2 / ≥3),连 `best1/best2` 换字符优化、
  `array('i')` 压缩内存、INF 取值理由都写清楚了——这是被逐轮重写打磨出来的,不是一次生成的;
- `tasks.json` 第 2、4 条都显式带着 **"report the SAMPLE TESTS verdict"** ——
  这是 manager 在样例判决驱动下给 worker 下的指令,§3.1 那个验证器在真实生效。

---

## 9. 循环的统计特征

同一批 100 题(Qwen3.8-27B,pass 1)上,manager 每题的总调用数:

```
min 5 · median 5 · mean 6.5 · max 28

  5 次 ████████████████████████████████████████████████████████████ 73
  7 次 █████████ 11
  8 次 ███ 4
  9 次 ███ 4
 11 次 ██ 2
 12 次 █ 1
 16 次 █ 1
 17 次 █ 1
 18 次 █ 1
 26 次 █ 1
 28 次 █ 1
```

调用数 = `3 + 2×轮数`(+ 截断摘要 + finalize)。所以:

- **73/100 题只跑了一轮**(plan + ideation + manage + worker + manage = 5 次)——
  manager 看过样例判决后当场签收。开销并不是均摊到每题的。
- 长尾一直拖到 28 次,那是硬闸反复把 `done` 打回去、逼着换路线的题。
- 12/100 题至少有一次调用被截断(单次调用那一侧是 17/100)。

对应分数(五遍平均 pass@1):

| | p1 | p2 | p3 | p4 | p5 | mean |
|---|---|---|---|---|---|---|
| manager | 83 | 86 | 88 | 85 | 90 | **86.4** |
| single | 71 | 69 | 60 | 66 | 62 | **65.6** |

---

## 10. 一句话总结

**用文件系统当持久 ledger 来对抗上下文窗口,用"经理每轮重排任务表 + 只派一件事"来对抗
流水线僵化,用真实执行样例的硬闸来对抗模型自我判定过于乐观。**

代价是约 3× 的 token 账单(论文 §2.2)。

---

## 附:自己跑一遍

```bash
python escalation/run_bench.py --engine multiagent --only lcb --lcb 100 \
       --ids-file escalation/lcb100_hardest_v6.json --parallel N --out results.json
```

把 `--engine` 换成 `single` 就是基线。轮次预算、模型路由、caps 和 reasoning 模式全部
由环境变量驱动(`MULTIAGENT_MAX_ITERS`、`MULTIAGENT_MODEL`、`MULTIAGENT_STRICT_FORMAT` …),
见 `orchestrator.py` 头部注释。

---
---

# 第二部分：Fable 5 / Opus-5 / GPT-5.6 / Qwen3.8 的 agent 对照分析

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

### 已就绪：agent 层 A/B（Claude Code 自己的 loop vs 论文的 manager）

这是核心实验 —— **模型固定，只换 agent 层**：

| | agent 层 | 由谁组织工作 |
|---|---|---|
| **A** | `--engine ccagent` | **Claude Code 自己的 loop**：`claude -p` + 工具 + 多轮，自主决策 |
| **B** | `--engine multiagent` | **论文的 v2 manager/worker 脚手架**（ledger workspace） |
| **C** | `--engine single` | 一次调用、无工具 —— 论文基线，用来把 A/B 锚回已发表的表 |

新增两个文件：

- **`escalation/ccagent.py`** —— 新引擎，签名与 `multiagent_solve()`/`single_solve()` 完全一致，
  所以能直接插进 `run_bench.py` 的同一个调用点。
- **`escalation/run_bench_script/run_agentloop_ab.sh`** —— 驱动 2×N 矩阵并打出对比表。

```bash
# 先冒烟
N=3 PASSES=1 MODELS=opus LAYERS="single ccagent" ./run_agentloop_ab.sh
# 完整
MODELS="opus fable" LAYERS="single multiagent ccagent" ./run_agentloop_ab.sh
```

**A 与 B 之间被刻意held住不变的**：题面（`run_bench.py` 把同一个 `build_code_prompt(prob)`
交给两者）、100 道题及其顺序、任务框架（`spec["solver_system"]` 原样前置）、返回契约
（```python fence，同一个 `extract_code(..., LMStyle.ClaudeCode)`）、评分、状态分类、regrade。
**唯一的差别就是谁来组织工作。**

**A 必然与其它臂不同的四点**，出数时必须一起标注：

1. **交付契约是额外加的。** 带工具的 agent 必须被告知答案放哪，所以 `DELIVERY_CONTRACT`
   会追加到 system prompt。manager 臂不需要这段文字（脚手架自己写 `solution.py`）。
   这是唯一的 prompt 不对称，无法避免，因此写得尽量短。
2. **无输出 cap、无 reasoning 开关、无 temperature。** `claude -p` 三者都不暴露。
   §2.1 各臂都钉在 128k，A 不是。
3. **A 能执行代码。** 它有 Bash，可以拿题面里的样例自测。v2 脚手架的 verifier 也做同样的事，
   所以 **A vs B 是公平配对**；但 **A vs C 不是** —— C 什么都跑不了。
4. **轮数预算是 CLI 自己的**，不是 `MULTIAGENT_MAX_ITERS`。受 CLI 的 loop 和
   `CCAGENT_WALL_SECONDS` 约束。

#### 三个模型怎么放进 A

- **Opus / Fable**：`CCAGENT_MODEL=opus|fable`，订阅 auth，**不需要 API key**。
- **Qwen**：layer A 只能通过 **Anthropic 兼容代理**接非 Anthropic 模型 ——
  `ANTHROPIC_BASE_URL` 指向 litellm（`claude_code_runner.py` 里的 `LITELLM_ENV` 就是这么做的，
  代理在 `:8216`）。脚本 `route()` 里的 `qwen` 行已经搭好，**用之前需要填自己的地址**。
  layer B/C 则走 orchestrator 原有的 `MULTIAGENT_MODEL` 前缀，两条路指向同一个 vLLM。

#### 实测出来的坑（脚本已内置拦截）

**必须以普通用户身份跑，不能用 root。** layer A 需要
`--permission-mode bypassPermissions`，agent 才能执行自己写的代码；**CLI 在 root/sudo 下
拒绝该模式**。

**不要用 `acceptEdits` 绕过。** 这是实测不是猜测：root + `acceptEdits` 下，agent
写出了 `solution.py`，但 **Bash 被拒绝 3 次**，最终消息自己承认
*"The verification step did not run"*。也就是说 agent 拿不到工具、验证不了 ——
**layer A 会静默退化成一个慢速单次调用**，而分数照样产出。这是本次最危险的一个坑。

拦截方式：`ccagent.py` 从 result 事件里抓 `permission_denials`，逐题写进
`status_out["permission_denied"]`；`run_bench.py` 把它持久化进 record；
驱动脚本的 `check()` 只要发现任何一题有 denial 就**判该 pass 不合格并要求重跑**。
`preflight()` 另外在 root + bypassPermissions 组合下直接拒跑。

顺带：result 事件还带 `total_cost_usd` 和 `modelUsage`，脚本会把每个 pass 的成本汇总打出来
（论文其它臂有成本列，这样 A 也能有）。

#### 已验证到什么程度

- **`ccagent_solve()` 真跑通了一次完整 agent loop**（`claude 2.1.250`，`opus`）：
  5 turns、1 个 thinking block、写出 `solution.py`、`extract_code` 提取一致、
  提取出的代码实跑 `3 4` → `7`。
- denial 捕获实测触发（3 次 Bash 拒绝被正确记录并告警）。
- `check()` 的六种失败态全部实测：id 不符 / `n_infra`≠0 / 有 denial / 崩溃残file /
  坏 JSON / 文件不存在。
- root 守卫实测：带 `ccagent` 时拒跑，只跑 `single` 时不拦。
- 汇总表渲染用合成数据验证过。
- **未做完整跑通**：本容器缺 `datasets`，且是 root（layer A 必然被拒）。

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

`run_claudecode_sub_5pass.sh`（上一版脚本）仍然可用，但它只覆盖 layer B/C ——
`claude_cli_chat()` 用 `--tools ""` 把 CLI 当单轮补全通道，agent 那层来自论文脚手架。
**`run_agentloop_ab.sh` 是它的超集**，三个 layer 一起跑，要做 A/B 用后者。

`codebase/livecodebench/.../claude_code_runner.py`（那个未收录实验的 runner）**没有被采用**：
它走 LCB 官方 runner，而官方 runner 没有 `--ids-file`（固定 id 逻辑是 escalation 独有的，
`run_bench.py:130-132`），题目集对不齐则数字无法与 85→91 / 87.4 / 86.4 比。
`ccagent.py` 绕开了这个问题 —— 把 agent loop 直接做成 escalation 的一个 engine，
于是复用了固定 id、题面、评分的全套。它的 `DELIVERY_CONTRACT` 思路借自
`claude_code_runner.py` 的 `AGENTIC_CONTRACT`，但刻意写得更短：
后者把"枚举边界情况、写 brute-force 做 stress test"等**解题方法**写进了 prompt，
那会让 A 拿到 B 没有的指导；`ccagent.py` 只保留"答案写进 `solution.py`"这一条交付约定，
解题方法一律留给两边共享的 `spec["solver_system"]`。

**其他可补的**：**其他可补的**：
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
