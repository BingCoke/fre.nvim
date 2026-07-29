# Task for scout

只读侦察这个 Neovim Lua 插件，目标是为以下用户报告建立精确上下文和回归测试入口：1) 在子目录点击 `../` 回到父目录后，cursor 应落在原来的子目录条目，而不是顶部 `../`；2) 点击 `../` 后不应继续展开刚离开的子路径，避免多余复杂行为；3) instance 在整个生命周期中不应保留任何“继承来源/父 instance”字段，所有状态只由传入 opts 决定。请检查相关 lua 与 tests，给出：实际调用链、当前可疑状态字段/函数、最合适的红色回归测试位置与具体断言、可能需要修改的最小文件集合。不要编辑文件，不要运行子代理，不要泛泛重述。注意工作区 prom.md 有用户改动，忽略它。

---
**Output:**
Write your findings to exactly this path: /Users/bingcoke/project/lua/fre.nvim/.pi-subagents/artifacts/outputs/7b059dd8/context.md
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