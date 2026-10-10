# Policy examples

One folder per policy in `platform/kyverno`. `scripts/policy-test.sh` (part of `validate.sh`) checks
that every `bad-*.yaml` is rejected **by that policy** and every `good-*.yaml` passes all policies.
A policy without a bad example fails the check.
