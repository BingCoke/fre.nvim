# Task for scout

[Read from: /Users/bingcoke/project/lua/fre.nvim/lua/fre, /Users/bingcoke/project/lua/fre.nvim/tests]

只读检查 /Users/bingcoke/project/lua/fre.nvim 中 `../` 导航行为。范围仅限 lua/fre/actions.lua、tree.lua、row.lua、buffer.lua、manager.lua、instance.lua 及直接相关 tests。目标：找出从点击/enter `../` 到重建 UI、设置 cursor、展开目录的调用链；指出导致回父目录后 cursor 在顶部以及旧子 path 仍展开的具体字段/函数；给出最小红色回归测试（测试文件与断言）。不得编辑，不得运行子代理，忽略 prom.md。输出压缩到 80 行内。

---
Update progress at: /Users/bingcoke/project/lua/fre.nvim/.pi-subagents/artifacts/progress/401c92d8/progress.md

---
**Output:**
Write your findings to exactly this path: /Users/bingcoke/project/lua/fre.nvim/.pi-subagents/artifacts/outputs/401c92d8/.pi-subagents/nav-recon.md
This path is authoritative for this run.
Ignore any other output filename or output path mentioned elsewhere, including output destinations in the base agent prompt, system prompt, or task instructions.

## Acceptance Contract
Acceptance level: attested
Completion is not accepted from prose alone. End with a structured acceptance report.

Criteria:
- criterion-1: Return concrete findings with file paths and severity when applicable

Required evidence: review-findings, residual-risks

Finish with a fenced JSON block tagged `acceptance-report` in this shape:
Use empty arrays when no items apply; array fields contain strings unless object entries are shown.
`criteriaSatisfied[].status` must be exactly one of: satisfied, not-satisfied, not-applicable.
`commandsRun[].result` must be exactly one of: passed, failed, not-run.
`manualNotes` and `notes` are optional strings; an empty string means no note and does not satisfy `manual-notes` evidence.
```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "specific proof"
    }
  ],
  "changedFiles": [
    "src/file.ts"
  ],
  "testsAddedOrUpdated": [
    "test/file.test.ts"
  ],
  "commandsRun": [
    {
      "command": "command",
      "result": "passed",
      "summary": "short result"
    }
  ],
  "validationOutput": [
    "validation output or concise summary"
  ],
  "residualRisks": [
    "none"
  ],
  "noStagedFiles": true,
  "diffSummary": "short description of the diff",
  "reviewFindings": [
    "blocker: file.ts:12 - issue found, or no blockers"
  ],
  "manualNotes": "anything else the parent should know"
}
```