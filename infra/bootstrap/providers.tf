# Like infra/terraform: no endpoints or credentials here. The environment decides
# whether this targets Floci or real AWS.
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "shortify"
      ManagedBy = "terraform-bootstrap"
    }
  }
}
