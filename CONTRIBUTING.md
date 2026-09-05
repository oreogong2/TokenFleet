# Contributing safely

Use the GitHub-provided `noreply` email for new commits, including commits made
by coding tools and web merges. Check the active checkout's configuration before
publishing. Do not copy your personal email into examples or privacy rules.

Keep machine-specific home paths, direct production IP addresses, private email
addresses, operational handoffs, credentials, and real user data outside this
public repository. Use example identities and RFC documentation networks in
fixtures. Public product URLs and the administrator's intentionally public
contact entry remain part of the user-facing installation flow.

Before pushing, run:

```sh
python3 -m unittest -v script/test_verify_public_privacy.py
python3 script/verify_public_privacy.py
```

For a branch, pass the full base commit SHA with `--base-ref` to also check new
commit identities. CI runs both checks without echoing matched personal values.
These checks supplement GitHub Secret Scanning and the existing source-archive
checks; they do not prove that every possible kind of private data is absent.

Published tags and fixed source commit URLs are compatibility contracts. Do not
rewrite release history or replace published artifacts as routine privacy
maintenance. Plan any historical removal separately with affected contributors
and release consumers.
