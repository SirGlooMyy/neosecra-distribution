# Token Rotation

## Schedule

| Token Type | Rotation Interval | Method |
|------------|-----------------|--------|
| GHCR Read (classic PAT) | 90 days | Manual — GitHub settings |
| Distribution Read (fine-grained PAT) | 90 days | Manual — GitHub settings |

## Rotation Procedure

1. Create new tokens following CUSTOMER-UPDATER-AUTH.md
2. Verify new tokens work:
   - GHCR: `docker pull` succeeds
   - Distribution: `curl` release metadata succeeds
3. Replace credential files on customer server
4. Verify old tokens are revoked
5. Update token metadata
6. Audit log the rotation

## Emergency Revoke

If a token is suspected compromised:

1. Revoke immediately via GitHub Settings > Tokens
2. Verify revocation:
   ```bash
   curl -s -H "Authorization: token <compromised-token>" \
     "https://api.github.com/repos/SirGlooMyy/neosecra-distribution" | grep -q "Bad credentials"
   ```
3. Generate replacement tokens
4. Install new tokens on customer server
5. Document the incident

## Customer Disable

To disable a customer's access:

1. Revoke both tokens
2. Remove package access in GHCR settings
3. Verify access is denied
4. Audit log the disable
