# Asgard (Valhalla rebuild) runbook

The new box is **Asgard**; **Valhalla** is the old box/stack being replaced.

**Status: DRAFT, UNTESTED.** Nothing here has been run. First deploy it as a throwaway test stack
(`foundrytest.infiniteaxis.tv`, Let's Encrypt staging, `ManageDns=false`), fix what breaks, and only then plan cutover.
The old `Valhalla` stack is never updated in place and is retired last.

## 0. Prerequisites

- The repo is the GitLab import of the `aws-foundry-ssl` fork (`RepoUrl` default `https://gitlab.com/valhalla-software/aws-foundry-ssl.git`, **confirm the real path**), with this folder at `asgard/` (`SetupPath` default `asgard/setup`). Push the `asgard/` changes to the branch named in `RepoBranch` (default `main`). In that project create a **deploy token** (Settings > Repository > Deploy tokens, scope `read_repository`, expiry a few days) and pass its name/value as `GitDeployUser` / `GitDeployToken`. Revoke it once the instance has cloned.
- Foundry download links expire in ~5 minutes, shorter than the build. Leave `FoundryDownloadLink` EMPTY. When setup finishes, generate a fresh Linux/Node link on foundryvtt.com and run `sudo /usr/local/sbin/asgard-install-foundry '<link>'` on the box.
- Create SSM parameters in us-east-2 (the box can read `/asgard/*` only):
  - `/asgard/kotw/env-local` (SecureString): full contents of kotw's `.env.local`, including `MANDALOR_DISCORD_USER_ID`.
  - `/asgard/claude-ops-pubkey` (String, optional): public key for the read-only `claude-ops` account.
- Foundry moves to **v14** on Asgard (decided; Degenesis and CPRed campaigns are paused). `FoundryNodeVersion` defaults to 24.22.1 (v14 minimum); use the newest 24.x patch at deploy time.
- Do the 12 -> 14 world migration **on Asgard, never on Valhalla**, so the old box stays a clean rollback. Foundry has historically migrated worlds one major generation at a time, so plan on: install v13 first, open each world to migrate it, update systems/modules to v13-compatible versions, then update to v14 and migrate again. **Verify the supported path on foundryvtt.com (Migration/Updating articles) before starting;** I could not confirm whether 12 -> 14 is allowed directly. Foundry also makes automatic world backups before major migrations; keep them.
- Before migrating, take a Foundry data backup (`/foundrydata`) and an EBS snapshot of Asgard.
- **Compatibility (checked 2026-11-11):** Degenesis (`the-silent-epidemic`) is verified on v14: migrate it. The Cyberpunk RED system is NOT v14-compatible (last verified on v12): **do not copy the CPRed world into Asgard's data, and never open/migrate it on v14.** Archive it instead (tarball of the world folder, the CPRed system folder and its module list) to S3 before Valhalla is retired. If CPRed is ever needed before it gets v14 support, deploy a second small stack from this same template with `FoundryNodeVersion=20.20.2` and a Foundry 12.x download link, then restore the archive there.
- Static IP / DNS: the new stack makes its **own** Elastic IP. Cutover is a DNS change, not an EIP move.

## 1. Trial deploy

```
aws cloudformation create-stack --stack-name Asgard-test --region us-east-2 \
  --template-body file://asgard/cloudformation/Asgard_Deployment.yaml \
  --capabilities CAPABILITY_IAM --on-failure DO_NOTHING \
  --parameters ParameterKey=HostedZoneId,ParameterValue=Z07010851LDVTXRVWM6JI \
    ParameterKey=AlertEmail,ParameterValue=YOU@example.com ParameterKey=LetsEncryptEmail,ParameterValue=YOU@example.com \
    ParameterKey=S3BucketName,ParameterValue=<existing bucket> ParameterKey=FoundryDownloadLink,ParameterValue='<url>' \
    ParameterKey=AdminSshPublicKey,ParameterValue='<ssh-ed25519 ...>'
```

`--on-failure DO_NOTHING` keeps a failed instance for debugging instead of rolling it back. Defaults keep the trial safe:
`ManageDns=false`, `LetsEncryptStaging=true`, `FoundrySubdomain=foundrytest`, no SSH rule (use SSM).

Watch: `aws ssm start-session --target <id>` then `tail -f /var/log/asgard-setup.log`.
The log ends with the GitLab **deploy public key**: add it read-only to `kotw`, `website`, `famblygameproject`.

Then: `sudo /usr/local/sbin/asgard-bootstrap-apps`, run the pipelines (or deploy by hand), `sudo -u axis pm2 save`.

### Trial checklist

- [ ] `systemctl is-active foundry nginx pm2-axis certbot-renew.timer` all active; `nginx -v` is nginx.org mainline
- [ ] `curl --resolve foundrytest.infiniteaxis.tv:443:<EIP> -k https://foundrytest.infiniteaxis.tv/api/status`
- [ ] Foundry Node is the pinned one (`ps` shows `/opt/foundry-node/current/bin/node`), system `node -v` is 24.x
- [ ] S3 via instance role works (upload an asset in Foundry). **If not**, see "S3 auth fallback"
- [ ] `stat -c '%a %U' /foundrydata/Config /foundrydata/Config/*` -> 700 / 600
- [ ] `sshd -T | grep -E 'permitrootlogin|passwordauth'`; `sudo -l -U gitlab-runner` shows only the two narrow rules; `sudo -l -U gitlab-lint` shows none
- [ ] CloudWatch log groups `/asgard/*` receive data; SNS confirmation mail accepted; StatusAlarm exists
- [ ] DLM policy ENABLED (first snapshot Monday 12:00 UTC)
- [ ] reboot test: everything returns without help
- [ ] ports from outside: 80, 443, 4000 only (22 only if `SshAllowedCidr` set)

## 2. Migrate data (during or right before cutover)

1. Quiesce on the old box: stop world activity, `sudo systemctl stop foundry`.
2. Archive `/foundrydata` (Data/worlds, Data/modules, Data/systems, Backups optional) with `tar` on the old box; move it through S3 or SSM. Prefer an S3 bucket object with a short-lived presigned URL over SFTP keys.
3. On the new box restore Data/* into `/foundrydata/Data`, and copy **only** `Config/license.json` and `Config/admin.txt` from the old box. **Do not** copy the old `options.json` or `aws-s3.json`: the new ones are generated.
4. `sudo chown -R foundry:foundry /foundrydata` then re-run the permission block (dirs 750, files 640, Config 700/600), `sudo systemctl restart foundry`.
5. Worlds to verify: `echoes-of-sentience`, `the-silent-epidemic`. Re-install modules/systems from within Foundry if anything is missing.
6. Delete the transfer archives afterwards (old box also has `~/foundrydata-2026-10-29.tgz` and `~/foundry-local-backup-20250619.tar.gz` to copy off then delete).

## 3. Cutover

Do this 1-2 days ahead: lower the `bot` record TTL from 86400 to 300 (apex and foundry are already 120).

1. On the **old** box: `sudo systemctl disable --now hosted_zone_ip.timer` (it would otherwise re-point foundry at the old IP every 24h). Pause the old runner (`sudo systemctl stop gitlab-runner`).
2. Update the new stack: `LetsEncryptStaging=false`, `FoundrySubdomain=foundry`, `ManageDns=true`. (Parameter updates do not rebuild the instance, but user data does not rerun; apply on the box instead:)
   - Re-issue production certs: `sudo /usr/local/sbin/asgard-issue-certs --production`
   - Edit `/etc/nginx/conf.d/foundry.conf` server_name/cert paths to the `foundry` name and `/foundrydata/Config/options.json` hostname, then `nginx -t && systemctl reload nginx && systemctl restart foundry`.
   - If a clean rebuild is cheaper than hand edits: delete the test stack and create a final stack with the final parameters (certs issue via DNS-01 in minutes).
3. Register the runners (create two **runner authentication tokens** in GitLab first: `production` = Protected, tag `production`; `lint` = tag `lint`): `sudo asgard-register-runners <prod-token> <lint-token>`.
   Remove the old box's `production` runner in GitLab so only one box deploys.
4. Switch DNS (Route 53, zone `infiniteaxis.tv`) to the new EIP: apex `A`, `www` (CNAME/alias as today), `bot` `A`, then `sudo systemctl enable --now asgard-dns.timer` (Foundry record).
5. Smoke test all four hostnames over HTTPS, MUD on port 4000, a Foundry login, an S3 upload, a pipeline run on `main`.
6. Keep the old box **running but idle** for ~2 weeks as rollback.

### Rollback

Point apex/www/bot/foundry back at `52.14.53.6`, `systemctl start foundry` and `systemctl enable --now hosted_zone_ip.timer` on the old box, restart the old runner. TTLs of 120-300 keep this fast.

## 4. CI file changes (in the app repos)

The old pipelines hard-code nvm paths and broad sudo. On the new box Node is system-wide and PM2 is `/usr/bin/pm2`.

- Drop the `NODE_BIN=/home/axis/.nvm/...` PATH logic; use plain `npm`/`pm2` (run as axis via `sudo -u axis`).
- website deploy: replace the `rm -rf` / `cp -r` / `chown` / `chmod` sudo lines with `sudo /usr/local/sbin/deploy-website` (build as axis; the script rsyncs `dist/website/browser`).
- lint jobs: add `tags: [lint]` and work in the runner's own workspace instead of `/home/axis/famblygameproject` (the old job switches the live directory's branch).
- Apps move from Node 22.23.4 to system Node 24: update `.nvmrc`/`engines`, run the test suites first. Set `NODE_APPS_MAJOR=22` in `40-apps.sh` if you want to stay on 22 (EOL ~April 2027).

## 5. Retire the old stack (last)

- The old stack **owns** the EIP, the apex Route 53 record, the SG, the DLM policy and the instance role. Deleting the stack releases the EIP and deletes the apex record. Do it only after DNS points elsewhere.
- Snapshot first (manual snapshot `snap-0b23039fd3659f27b` exists; take a fresh one). If stack deletion fails on drift (deleted IAM users), delete with retain on the failing resources.
- Afterwards: delete the stray manual snapshot, remove `foundry-s3-user` if unused, remove the old deploy key from GitLab, rotate `strix-ssm`. Its policy only allows `ssm:StartSession` on the OLD instance (`i-0e5d4a5891043de8f`) with `AWS-StartSSHSession`, so Strix/Claude Code cannot reach Asgard until the policy gets Asgard's instance ID (do this at cutover, then drop the old ID).

## Known gaps / TODO before trusting this

- Everything above is unrun. Expect typos; check shell scripts with `shellcheck` and the template with `cfn-lint`.
- NodeSource repo URL/key and the nginx.org repo file are written by hand from memory of the vendor layout; verify at first run.
- Foundry `awsConfig` path/format and credential-chain behaviour are unverified.
- Disk-usage CloudWatch alarm is a TODO (needs agent dimensions).
- GitLab runner package key expires 2027-02-26: update `EXPECTED_FPR` in `50-runner.sh` when it rotates.
- Foundry TURN/UDP is closed; add 33478/udp and 49152-65535/udp back only if voice/video needs it.

### S3 auth fallback

If Foundry will not use the instance role, create a dedicated IAM user limited to the one bucket, store its keys in SSM SecureString, and have `20-foundry.sh` write them into `aws-s3.json` (mode 600). Never put them in CloudFormation parameters or user data.
