# First-time setup

Manual, one-time steps to bring a new clone of this repo to a working state.
Re-run any section if the underlying credential is rotated or the host is
rebuilt.

## 1. Local prerequisites (home Mac)

```bash
# Xcode command-line tools (Swift)
xcode-select --install

# Homebrew (if not already)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# pnpm (worker development)
brew install pnpm

# wrangler (Worker deploys)
brew install cloudflare-wrangler2

# gh CLI (already required to create the repo)
brew install gh
```

Verify:

```bash
swift --version            # >= 5.10
pnpm --version             # >= 9
wrangler --version         # >= 3.62
gh --version               # >= 2.40
```

> **swift-testing note:** the Swift Package's tests use `swift-testing`, whose
> macOS module ships with Xcode rather than the bare command-line tools. If
> `swift test` reports `no such module 'Testing'`, point the toolchain at Xcode:
>
> ```bash
> sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
> ```

## 2. Cloudflare account (Worker deploys)

1. Sign up at https://dash.cloudflare.com (free plan is enough).
2. From the dashboard, copy your **Account ID** (sidebar of the Workers & Pages section).
3. Create a scoped API token: **My Profile → API Tokens → Create Token →
   Custom Token** with the following permissions:
   - **Account → Workers Scripts → Edit**
   - **Account → Workers KV Storage → Edit**
   - Account resource: the account from step 2.

   Copy the token; it's shown once.

4. Provision both as GitHub repository secrets:

   ```bash
   gh secret set CLOUDFLARE_API_TOKEN
   gh secret set CLOUDFLARE_ACCOUNT_ID
   ```

   Paste each value when prompted.

## 3. Register the self-hosted GitHub Actions runner (home Mac)

This runner executes deploy workflows. It does **not** run CI (CI uses
free github-hosted runners).

1. In the repo: **Settings → Actions → Runners → New self-hosted runner**.
   Select **macOS** and the **arm64/x64** matching your Mac.

2. Follow the on-screen download + configure commands; the registration
   step looks like:

   ```bash
   mkdir ~/actions-runner && cd ~/actions-runner
   curl -o actions-runner-osx.tar.gz -L https://github.com/actions/runner/releases/download/v2.319.1/actions-runner-osx-arm64-2.319.1.tar.gz
   tar xzf actions-runner-osx.tar.gz
   ./config.sh --url https://github.com/volovely/lamp-controller \
               --token <REGISTRATION_TOKEN_FROM_GITHUB> \
               --name lamp-mac \
               --labels self-hosted,macOS,lamp-mac \
               --work _work \
               --unattended
   ```

   The exact registration token and download URL are shown by GitHub on the
   page — use those, not these.

3. Install the runner as a launchd service so it survives logout/reboot:

   ```bash
   cd ~/actions-runner
   ./svc.sh install
   ./svc.sh start
   ./svc.sh status
   ```

   Expected last line: `actions.runner.volovely-lamp-controller.lamp-mac (running)`.

4. Confirm the runner appears as **Idle** in **Settings → Actions → Runners**.

5. Sanity check — manually trigger a deploy workflow:

   Once `deploy-worker.yml` exists (Stage 2), trigger it with:

   ```bash
   gh workflow run deploy-worker.yml
   gh run watch
   ```

   It should pick up the `lamp-mac` runner.

## 4. Gmail (Stage 3)

Not yet needed at Stage 0. When Stage 3 lands:

1. Enable 2-Step Verification on the Gmail account.
2. Generate an App Password (16-char): https://myaccount.google.com/apppasswords
3. `cd worker && wrangler secret put IMAP_APP_PASSWORD`.

## 5. Anthropic API key (Stage 3)

Not yet needed at Stage 0. When Stage 3 lands:

1. Sign in at https://console.anthropic.com.
2. Create an API key.
3. `cd worker && wrangler secret put ANTHROPIC_API_KEY`.

## 6. Homebridge (Stage 1)

Not yet needed at Stage 0. Setup is captured in
[`homebridge/README.md`](../../homebridge/README.md) during Stage 1.
