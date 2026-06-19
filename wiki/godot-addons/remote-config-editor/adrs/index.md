# ADRs

**Status:** active

## Overview
Decisions behind the addon: project config lives outside the addon folder, the publish payload is spliced verbatim for numeric fidelity, and drift is checked via one external project-supplied comparator.

## Contents
- [Project-specific config lives outside the addon folder, in res://remote_config_editor.config.json](decision-record:mql8psw7-02fm-3m42ke)
- [The publish payload splices each blob's raw on-disk JSON verbatim, preserving numeric fidelity](decision-record:mql8pu6g-02fo-u6g62c)
- [Drift check shells out to one project-supplied comparator, never reimplemented in GDScript](decision-record:mql8pvhe-02fq-gvm621)
