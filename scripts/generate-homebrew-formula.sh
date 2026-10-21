#!/usr/bin/env bash

set -euo pipefail

FORMULA_CLASS=""
HOMEPAGE=""
VERSION=""
URL=""
SHA256=""
DESCRIPTION="Give AI agents eyes and hands on iOS Simulator and Android devices"
LICENSE_NAME="Apache-2.0"
NOTARIZED=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --formula-class)
      FORMULA_CLASS="${2:-}"
      shift 2
      ;;
    --homepage)
      HOMEPAGE="${2:-}"
      shift 2
      ;;
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --url)
      URL="${2:-}"
      shift 2
      ;;
    --sha256)
      SHA256="${2:-}"
      shift 2
      ;;
    --description)
      DESCRIPTION="${2:-}"
      shift 2
      ;;
    --license)
      LICENSE_NAME="${2:-}"
      shift 2
      ;;
    --notarized)
      NOTARIZED=true
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$FORMULA_CLASS" || -z "$HOMEPAGE" || -z "$VERSION" || -z "$URL" || -z "$SHA256" ]]; then
  echo "Missing required arguments" >&2
  echo "Usage: $0 --formula-class CLASS --homepage URL --version VERSION --url URL --sha256 SHA256 [--description TEXT] [--license NAME] [--notarized]" >&2
  exit 1
fi

POST_INSTALL_BLOCK=""
if [[ "$NOTARIZED" != "true" ]]; then
  POST_INSTALL_BLOCK='
  def post_install
    system "codesign", "--force", "--sign", "-", "--timestamp=none", libexec/"sim-use"
  end
'
fi

cat <<EOF
class ${FORMULA_CLASS} < Formula
  desc "${DESCRIPTION}"
  homepage "${HOMEPAGE}"
  license "${LICENSE_NAME}"
  version "${VERSION}"
  depends_on macos: :sonoma

  url "${URL}"
  sha256 "${SHA256}"

  def install
    libexec.install "sim-use", "SimUse_SimUse.bundle", "SimUse_AndroidBackend.bundle"
    bin.write_exec_script libexec/"sim-use"
  end
${POST_INSTALL_BLOCK}
  test do
    assert_match version.to_s, shell_output("#{bin}/sim-use --version")
  end
end
EOF
