#!/usr/bin/env bash
# ==============================================================================
# NeoSecra Assessment — 1.1.4 PUBLISH ADIMLARI (HAZIRLIK)
# ==============================================================================
# Bu script 1.1.4 release'inin publish adımlarını belgeler.
# Kullanıcı kararı BEKLENİYOR: publish kaynağı (geliştirici makinesi / CI)
# ve DNS stratejisi (gerçek DNS / hosts) kararlaştırıldıktan sonra çalıştırılacak.
#
# ÖN KOŞULLAR:
#   1. build-release.sh ile distribution.tar.gz oluşturulmuş olmalı
#   2. minisign imzalama anahtarı ~/.neosecra/update-signing.key mevcut olmalı
#   3. Caddy root CA update-server/ca/update-neosecra-com-root.crt mevcut olmalı
#      (production'da running Caddy container'ından extract-ca.sh ile çekilir)
#   4. GHCR image'ları build edilmiş ve push'lanmış olmalı:
#      - ghcr.io/sirgloomyy/neosecra-assessment/security-health-backend:1.1.4
#      - ghcr.io/sirgloomyy/neosecra-assessment/security-health-frontend:1.1.4
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "============================================"
echo " 1.1.4 PUBLISH HAZIRLIK — SADECE PLANLAMA"
echo "============================================"
echo ""
echo "ADIM 1: CA sertifikasını güncelle (gerekirse)"
echo "  cd ${REPO_ROOT}"
echo "  bash update-server/ca/extract-ca.sh"
echo ""
echo "ADIM 2: Distribution archive'ı build et"
echo "  bash update-server/build-release.sh 1.1.4"
echo ""
echo "ADIM 3: Build edilen artifact'leri stage'le ve imzala"
echo "  bash update-server/publish.sh \\"
echo "    --product assessment \\"
echo "    --channel stable \\"
echo "    --version 1.1.4 \\"
echo "    --archive update-server/www/releases/1.1.4/distribution.tar.gz \\"
echo "    --key ~/.neosecra/update-signing.key"
echo ""
echo "ADIM 4: (OPSİYONEL) Docker bundle varsa ekle"
echo "  bash update-server/publish.sh \\"
echo "    ... (yukarıdaki parametreler) \\"
echo "    --bundle /path/to/docker-bundle-1.1.4.tar.zst"
echo ""
echo "ADIM 5: Update sunucusuna deploy (rsync)"
echo "  bash update-server/publish.sh \\"
echo "    ... (yukarıdaki parametreler) \\"
echo "    --rsync user@update.neosecra.com:/srv/update"
echo ""
echo "ADIM 6: Kanal JSON'unu repo'ya commit et"
echo "  git add channels/assessment-stable.json"
echo "  git commit -m 'chore(channel): assessment-stable 1.1.4'"
echo ""
echo "ADIM 7: Doğrulama"
echo "  # Update sunucusundan kontrol:"
echo "  curl --cacert ${REPO_ROOT}/update-server/ca/update-neosecra-com-root.crt \\"
echo "    https://update.neosecra.com/channels/assessment-stable.json | python3 -m json.tool"
echo "  # Bootstrap test:"
echo "  curl --cacert ${REPO_ROOT}/update-server/ca/update-neosecra-com-root.crt \\"
echo "    https://update.neosecra.com/releases/1.1.4/bootstrap.sh | bash"
echo ""
echo "============================================"
echo " KARAR BEKLENEN KONULAR"
echo "============================================"
echo " 1. DNS stratejisi: gerçek DNS kaydı mı, hosts mu?"
echo "    → docs/T7-DNS-PUBLISH-ANALYSIS.md"
echo ""
echo " 2. Publish kaynağı: geliştirici makinesi mi, CI mi?"
echo "    → docs/T7-DNS-PUBLISH-ANALYSIS.md"
echo ""
echo " 3. İmzalama anahtarı: ~/.neosecra/update-signing.key hazır mı?"
echo ""
echo " Bu adımlar kullanıcı kararı sonrası uygulanacak."
echo "============================================"
