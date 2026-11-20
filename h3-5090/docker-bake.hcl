variable "PACKAGE" {}
variable "GITHUB_SHA" {}

group "default" {
  targets = ["encoder", "render"]
}

target "common" {
  context = "."
  dockerfile = "Dockerfile"
  platforms = ["linux/amd64"]
  attest = []
}

target "encoder" {
  inherits = ["common"]
  target = "encoder"
  tags = ["${PACKAGE}:h3-5090-encoder-${GITHUB_SHA}"]
}

target "render" {
  inherits = ["common"]
  target = "render"
  tags = ["${PACKAGE}:h3-5090-render-${GITHUB_SHA}"]
}
