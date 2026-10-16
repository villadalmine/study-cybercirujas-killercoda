"

  head1 "Objective 2 - the pipeline can publish again"
  check     "the role uploads to builds/" upload_builds
  check     "the role can list the artifact bucket" \
            aws_lab --profile deploy s3 ls "s3://$BUCKET"

  head1 "Objective 3 - the guardrails you were not asked to remove"
  check_not "the role STILL cannot write to releases/ (boundary preserved)" \
            upload_releases
  check_not "the role STILL cannot call iam:CreateUser" \
            simulate_allows "iam:CreateUser" "arn:aws:iam::${ACCOUNT_ID}:user/newbie"
  check_not "the role STILL cannot delete the artifact bucket" \
            simulate_allows "s3:DeleteBucket" "arn:aws:s3:::$BUCKET"
  check_not "the trust policy was not opened to every principal" \
            grep -qE '"Principal"[[:space:]]*:[[:space:]]*"\*"' \
                 "$LAB_ROOT/iam/trust/LabDeployRole.json"

  head1 "Objective 4 - the audit finding"
  check     "no long-lived root credentials remain on this host" no_root_credentials

  printf '\n'
  if [ "$FAILED" -eq 0 ]; then
    printf '%sALL %d CHECKS PASSED.%s The pipeline is repaired and every guardrail survived.\n' \
           "$C_GREEN$C_BOLD" "$PASS" "$C_RESET"
    say "Read the commented solution at the bottom of this script and compare it with"
    say "what you actually did - the reasoning matters more than the diff."
    return 0
  fi
  printf '%s%d passed, %d still failing.%s  Try:  %s hint 1\n' \
         "$C_YELLOW$C_BOLD" "$PASS" "$FAILED" "$C_RESET" "$0"
  return 1
}

cmd_reset() {
  [ -f "$LAB_ROOT/$MARKER" ] || { fail "lab: nothing to reset at $LAB_ROOT"; exit 1; }
  rm -rf "$LAB_ROOT/aws" "$LAB_ROOT/iam" "$LAB_ROOT/org" "$LAB_ROOT/s3" "$LAB_ROOT/state"
  build_lab
  say "lab: sandbox reset - all four faults are back in place."
}

cmd_clean() {
  if [ -f "$LAB_ROOT/$MARKER" ]; then
    rm -rf "$LAB_ROOT"
    say "lab: removed $LAB_ROOT"
  else
    warn "lab: $LAB_ROOT is not a lab sandbox (no $MARKER marker) - refusing to delete."
    exit 1
  fi
}

case "${1:-start}" in
  start)  shift || true; cmd_start "${1:-}" ;;
  shell)  cmd_shell ;;
  verify) cmd_verify ;;
  hint)   shift || true; cmd_hint "${1:-1}" ;;
  reset)  cmd_reset ;;
  clean)  cmd_clean ;;
  brief)  cat "$LAB_ROOT/BRIEF.txt" ;;
  *)      say "usage: $0 {start|shell|verify|hint N|reset|clean|brief}"; exit 1 ;;
esac
