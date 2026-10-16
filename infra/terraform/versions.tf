terraform {
  required_version = ">= 1.8"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # aws_lambdacore_network_connector は 6.61.0 で追加された
      version = "~> 6.69"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }

  # 検証用のため state はローカルに置く（*.tfstate はコミットしない）
}
