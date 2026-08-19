class Edgetunnel < Formula
  desc "Deploy and verify EdgeTunnel on Cloudflare Pages"
  homepage "https://iwecon.github.io/auto-deploy-edgetunnel/"
  head "https://github.com/iwecon/auto-deploy-edgetunnel.git", branch: "main"

  depends_on xcode: ["15.0", :build]

  def install
    system "swift", "build", "--configuration", "release", "--disable-sandbox"
    bin.install ".build/release/edgetunnel"
  end

  test do
    assert_match "edgetunnel [deploy]", shell_output("#{bin}/edgetunnel --help")
  end
end
