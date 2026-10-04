- Push work to a new branch named agent/<topic> (short, lowercase, hyphens),
  never to main or to a developer's branch unless the task names that
  branch.
- Commit only source changes. Never commit build artefacts or caches
  (__pycache__/, *.pyc, node_modules/, dist/, build/, .venv/, coverage
  output); if the repository has no .gitignore for them, leave them
  unstaged and say so.
- Keep test runs to the packages a change touches unless asked for more.
- Say in your answer what you changed, the branch and commit, and what you
  ran to check it.
