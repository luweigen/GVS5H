# 多 Agent 的分工与协作机制

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
