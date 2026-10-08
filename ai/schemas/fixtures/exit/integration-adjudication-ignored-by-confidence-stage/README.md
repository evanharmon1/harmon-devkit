# integration-adjudication-ignored-by-confidence-stage

harmon-devkit#1240 criterion 2. A run that reached integration holds `adjudications/integration-r1.json`, whose findings were PR review comments and so have no pass or slot_failures record by design. The challenge stage's own two rounds still converge. Before the fix every confidence stage of such a run returned `indeterminate` ("adjudication document \"integration-r1\" names integration round 1, but no pass or slot_failures record…"). A confidence-stage orphan is still refused: see `adjudication-without-source-pass-rejected`.
