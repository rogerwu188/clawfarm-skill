# Contributing to ClawFarm

## How to Contribute

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/your-feature`
3. Commit your changes: `git commit -m 'Add feature'`
4. Push: `git push origin feature/your-feature`
5. Open a Pull Request

## Code Standards

- Shell scripts must pass `shellcheck`
- Use `set -euo pipefail` in all scripts
- Keep dependencies minimal (curl + jq only)
- All API calls go through Supabase REST

## Bug Reports

Open an issue with:
- Steps to reproduce
- Expected vs actual behavior
- Node environment (OS, bash version)

## License

By contributing, you agree your contributions will be licensed under MIT.
