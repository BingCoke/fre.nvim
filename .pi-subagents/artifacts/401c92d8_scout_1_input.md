# Task for scout

[Read from: /Users/bingcoke/project/lua/fre.nvim/lua/fre/instance.lua, /Users/bingcoke/project/lua/fre.nvim/lua/fre/inheritance.lua, /Users/bingcoke/project/lua/fre.nvim/lua/fre/manager.lua, /Users/bingcoke/project/lua/fre.nvim/lua/fre/init.lua, /Users/bingcoke/project/lua/fre.nvim/lua/fre/config.lua, /Users/bingcoke/project/lua/fre.nvim/tests/instance_spec.lua, /Users/bingcoke/project/lua/fre.nvim/tests/state_inheritance_spec.lua, /Users/bingcoke/project/lua/fre.nvim/tests/manager_spec.lua]

只读检查 /Users/bingcoke/project/lua/fre.nvim 的 instance 生命周期和所谓 inheritance。范围仅限 lua/fre/instance.lua、inheritance.lua、manager.lua、init.lua、config.lua 及 tests/instance_spec.lua、state_inheritance_spec.lua、manager_spec.lua。用户要求：instance 不应有任何继承字段或来源 instance 引用，一切只由传入 opts 决定。请列出当前构造链、所有继承相关字段/参数/函数及用途，指出可删除或需转成 opts 的最小改动，以及对应红色测试。不得编辑，不得运行子代理，忽略 prom.md。输出压缩到 80 行内。

---
Update progress at: /Users/bingcoke/project/lua/fre.nvim/.pi-subagents/artifacts/progress/401c92d8/progress.md

---
**Output:**
Write your findings to exactly this path: /Users/bingcoke/project/lua/fre.nvim/.pi-subagents/artifacts/outputs/401c92d8/.pi-subagents/instance-recon.md
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