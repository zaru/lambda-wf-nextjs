provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project    = var.project
      ManagedBy  = "terraform"
      Repository = var.github_repository
    }
  }
}

# CloudFront 用の ACM 証明書は us-east-1 に作る必要がある
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project    = var.project
      ManagedBy  = "terraform"
      Repository = var.github_repository
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}
