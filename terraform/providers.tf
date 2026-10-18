provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project = "ha3tier"
      Owner   = var.owner
      Env     = var.environment
    }
  }
}
