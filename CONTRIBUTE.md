# Contributing to Moodle on Azure 

The TL;DR version is:

  * We are a community project
  * We seek to make decisions through community consensus
  * We prefer debate through gradual improvement through pull requests to endless discussion about the "perfect" solution
  * We are a meritocracy, not a democracy
  * We welcome all your contributions including but not limited to feature requests, bug-reports, documentation and code
  
## How the project is managed

This project welcomes contributions and suggestions. Our goal is to
work on Azure specific tooling for deploying and managing the open
source [Moodle](http://moodle.org) learning management system on
Azure. We do not work on Moodle itself here, instead we work upstream
as appropriate.

The short version of how to contribute to this project is "just do
it". Where "it" can be defined as any valuable contribution (and to be
clear, asking questions is a valuable contribution):

  * ask questions
  * provide feedback
  * write or update documentation
  * help new users
  * recommend the project to others
  * test the code and report bugs
  * fix bugs and issue pull requests
  * give us feedback on required features
  * write and update the software
  * create artwork
  * translate to different languages
  * anything you can see that needs doing

Most contributions require you to agree to a Contributor License
Agreement (CLA) declaring that you have the right to, and actually do,
grant us the rights to use your contribution. For details, visit
https://cla.microsoft.com.

When you submit a pull request, a CLA-bot will automatically determine
whether you need to provide a CLA and decorate the PR appropriately
(e.g., label, comment). Simply follow the instructions provided by the
bot. You will only need to do this once across all repos using our
CLA.

## Decision Making

This is a community project. Decisions are made through consensus
building. All voices are equal and we welcome input from everyone.

That said, this is not a democracy. Consensus does not mean everyone
has to agree. It merely means that nobody is objecting *and* offering
an alternative.

What this means, in practive, is that she who does the work makes the
decisions. We'd rather discuss how to improve imperfect code than
argue over what would make perfect code. So if you have an objection
to the way we are doing things issue a pull request.

In the unlikely event that we cannot reach consensus through consensus
then the project maintainers (as identified by their having the admin
bit on GitHub) will make a judgetment call. But normally their
role is to guide the community to consensus action, not to make
decisions on bhalf of the community.

## Minimum Bar for Contributions

As the project matures we will add more thorough testing. It is expected
that all contributions pass the currently available suite of tests. If
they do not then they will be rejected.

It is also required that contributions which add features also bring
at least basic testing of that feature.

## Local Validation

Use pre-commit 4.4 or newer with Bash, Git, jq and Go available. Hook revisions
are pinned and their native tool environments are cached; Docker and Azure
credentials are not required. The first run downloads public dependencies.

From the repository root:

```bash
export PRE_COMMIT_HOME="$PWD/.cache/pre-commit"
pre-commit install --hook-type pre-commit --hook-type pre-push
pre-commit run --all-files
pre-commit run --hook-stage pre-push --all-files
```

If Git uses a shared `core.hooksPath`, do not overwrite the shared hook. With
Git 2.54+ and pre-commit 4.6+, register repository-local commands alongside it:

```bash
git config --local hook.pre-commit.pre-commit.event pre-commit
git config --local hook.pre-commit.pre-commit.command 'env PRE_COMMIT_HOME=.cache/pre-commit pre-commit hook-impl --hook-type pre-commit --'
git config --local hook.pre-commit.pre-push.event pre-push
git config --local hook.pre-commit.pre-push.command 'env PRE_COMMIT_HOME=.cache/pre-commit pre-commit hook-impl --hook-type pre-push --'
```

Commit hooks check staged JSON/YAML/XML, shell syntax, ShellCheck, check-only
shell formatting, Python lint and secrets. Gitleaks checks staged changes with
redacted output; `--all-files` does not turn that hook into a history scan.
The broader runtime contracts run at pre-push or manual stage with mocked
commands, not provisioning scripts. They require jq and do not prove Azure
provider acceptance.

### Native ARM Checks

On Linux x86_64, bootstrap the pinned PowerShell, ARM-TTK and PSRule tools once.
Downloads stay in the ignored workspace cache; the bootstrap verifies the
PowerShell and ARM-TTK archive checksums. No container, system installation,
Azure login or Az.Accounts module is required.

```bash
bash etc/installArmTools.sh
bash etc/checkArmTemplates.sh Schemas
bash etc/checkArmTemplates.sh SelfTest
pre-commit run arm-contracts --hook-stage pre-push --all-files
pre-commit run arm-best-practices --hook-stage manual --all-files
```

The pre-push ARM gate checks every local deployment template, resource API,
linked-template parameter/output contract, retained database/search route,
consumer parameter name and referenced script. Cached schemas check literal
resource shapes. Mutation tests verify that deliberately broken contracts and
invalid resource values fail. A missing tool, catalog, schema or linked target
is an error, not a skipped success. Checks use the current local revision, not
the upstream `_artifactsLocation` URL.

The strict manual audit runs both ARM-TTK and PSRule and writes bounded JSON
reports under `.cache/arm-tools/reports`. ARM-TTK stages repository artifacts
only. PSRule expands each template independently with generated dummy parameter
files and a common object evaluated from the root template. External
`templateLink` children are not expanded by PSRule, so root-only scanning is
insufficient. Explicit expansion and evaluated-rule counts prevent empty scans
from passing. The full audit currently fails on existing security/design debt
and reports unsupported-resource or rule-engine coverage gaps; these are not
blanket-suppressed or treated as production certification.

The API catalog records per-resource stable versions and pinned Microsoft
schema sources. MySQL 8.4 retains a documented preview-API exception; the VMSS
instance-NIC read uses its separately documented Network operation contract.
Deployment APIs and operation APIs are not interchangeable. API age is not
evidence of retirement. Elasticsearch provisioning and its dedicated templates
are unchanged by this update; exact file-scoped API pins keep those templates
under contract and shape checks without upgrading their deployment APIs.
Published schema versions are not observed subscription defaults. Uniform VMSS
orchestration is explicit to avoid API-default behavior changes; this is not
an egress or database-TLS hardening change.

The shape check allows unevaluated ARM expression leaves and overlapping
generated expression alternatives. It reports narrow normalization of the
published Recovery Services polymorphic-base schema contradiction while still
checking derived policy properties. It cannot validate evaluated names,
provider acceptance, region/SKU availability, permissions, guest provisioning
or backup recovery. Secure/external references may remain placeholders.

Microsoft's [ARM-TTK guidance](https://learn.microsoft.com/azure/azure-resource-manager/templates/test-toolkit),
[linked-template guidance](https://learn.microsoft.com/azure/azure-resource-manager/templates/linked-templates)
and [PSRule template expansion](https://azure.github.io/PSRule.Rules.Azure/using-templates/)
describe these separate validation layers. Azure validation and what-if are
authenticated cloud operations, even at Template validation level; they are
not offline emulators and are never invoked by these hooks.

The full scan currently exposes legacy ShellCheck and shell-formatting
findings. Do not hide these with blanket exclusions or reformat unrelated
files. The formatter hook never rewrites files; make intentional fixes and
rerun the affected checks. Optional integration or VM image builds remain
separate from Git hooks.

### Offline CI Runtime

Travis uses Ubuntu Noble, Node 24.22.1 LTS and Python 3.15.1. The image's Python
3.14 bootstraps pinned uv 0.13.5; validation runs in an isolated Python 3.15.1
environment with pre-commit 4.7.0. Grunt dependencies are exact and the npm
lockfile is checked in; use `npm ci --ignore-scripts` before `npm test`.

The existing Python entry point now runs only npm, native pre-commit,
pre-push ARM/runtime contracts and ARM mutation tests. It no longer imports
the legacy Azure deployment tester or generates deployment credentials.
Run it with the chosen validation interpreter and pinned Node on `PATH`:

```bash
export PRE_COMMIT_HOME="$PWD/.cache/pre-commit"
python -W default etc/travis.py
```

The whole-repository lint scan remains strict and currently reports legacy
shell lint/formatting debt. The separate legacy live-deployment tester has not
been ported or certified. No default CI step provisions or deletes resources.

## Planning

This is an open source project. We have a few mantras to ensure
efficient collaboration, these mostly boil down to ensuring good
visibility into the communities goals. These include:

  * If it didn't happen in public, it didn't happen
  * Scratch your own itch
  
### If it didn't happen in public, it didn't happen (aka full transparency)

The goal of this mantra is to ensure maximum visibility into our
communities work in order to:

  1. Provide an opportunity for community feedback in order to ensure
     our plans are good
  2. Provide a clear indication of what will be done, what may be done
     and what won't be done
  
Both of these goals lead to the second mantra "Scratch your own itch".

### Scratch your own itch (aka getting what you want)

This is an open source project. We welcome feature requests and, as a
community, we will provide feedback on whether we intend to work on it
or not. To this end we categories feature requests in one of 4 ways:

  * Priority 0 (will address)
  * Priority 1 (may address)
  * Priority 2 (maybe one day)
  * wontfix (out of scope)

Using these priorities it is easy for community members to decide
where to spend their time. For example:

  * Priority 0 items are actively being worked on by at least one
    community member. Others are welcome to contribute as appropriate
    (reviews are particularly important)
  * Priority 1 items are seen as important and are likely to be worked
    on in the short to medium term, but there is no community member
    active on the project at this time. Community members are welcome
    to take ownership of these issues and propose a solution that they
    intend to implement. If the community accepts the proposal then it
    will become a Priority 0 issue.
  * Priority 2 items are seen as interesting proposals that are not in
    conflict with the projects goals but are unlikely to be worked on
    by any existing communty members. Community members who have a
    need for these items are strongly encouraged to identify
    themselves and offer a proposal for a solution. If there is enough
    support within the existing community this item can become a
    Priority 0 under your leadership.
  * Wontfix items are considered out of scope for this project.
    Community members should seek to solve the problem in different
    ways. Often this will mean contribution to Moodle itself or a
    plugin that is external to this community.

## Community roles

This section outlines roles and responsibilities within the community.

### Users

Users self-identify by using our software and documentation. Their
responsibilities are to benefit from our work, but we welcome
contributions from users, such as:

  * Ask questions
  * Answer questions
  * Feature requests
  * Bug reports
  * Design reviews
  * Planning reviews
  * Evangelize the project
  * and more...
  
Some users will become more involved with the project, those users
become Contributors.

### Contributors

Contributes self-identify by making longer term commitments to our
project. Their responsibilities are to help the project be succesful
by ensuring that our work matches the needs of our users.
Possible contributions can include:

  * Everything a User might contribute
  * Remove blocks for users
  * Provide design input
  * Review pull requests
  * Implement features
  * Triage questions, feature requests and bug reports
  * and more...
  
Some contributors will become very engaged and therefore become an
essential part of the community, these contributors will become
Maintainers.

### Maintainers

We are fans of efficient processes. Maintainers are people who insert
themselves into our process to ensure they run well. The goal is to
empower our contributors who in turn focus on delighting our users.
Maintainers contributions may include:

  * Everyting Users and Contributors do
  * Merge pull requests where appropriate
  * Seek community consensus where conflict occurs
  * Remove blocks for contributors
  * and more...

## Pull requests, Review and Merges

We like efficient processes. Anyone is welcome to issue pull requests.
Everyone is encouraged to review pull requests. Maintainers are
responsible for merging pull requests but they are not responsible for
reviews, that is a community wide responsibility.

We operate under two models of review process as appropriate to each
circumstance:

  * Merge then Review (our preferred model)
  * Review then Merge
  
### Merge Then Review

In the "merge then review" model a maintainer will merge the pull
request into with minimal review. Community members are still expected
to review the code, but it is done after the fact.

The goal is to get the code into a shared repository as early as
possible. This allows people, including advanced users, to start
testing it. This ensures we have the maximum possible exposure to
testing in real scenarios early in the process. Encouragin bug reports
from the whole community ensures we have visibility into breaks as
early as possible.

This model has its risks, however. If a PR is on the critical path or
it is controversial in some way it is expected that maintainers will
ensure it recieves a thorough review before merging (see next section
on "Review then Merge". This decision is at the discretion of the
maintainer who first triages the pull request.

Should a mistake be made and a bad merge be performed then it can
often be easier and faster to fix it under the "Merge then Review"
model than it is to provide feedback to the original author and await
a fix from them. Should the mistake have a high impact and/or no easy
fix is available we simply roll back the merge and provide feedback
via the review process.

It should be noted that this model means that maintainers have the
right to simply merge their own code and expect others to review it
*after*. Maintainers are expected to use their best judgement when
excercising this priviledge.

### Review Then Merge

Where a change is on the critical path or it is potentiall
contriversial maintainers should request reviews using the GitHub
tooling. The last reviewer to sign-off on the pull request will merge
the pull request.

