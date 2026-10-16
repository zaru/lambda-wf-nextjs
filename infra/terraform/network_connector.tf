# Lambda が Connector の ENI を作るときに引き受けるロール（実行ロールとは別）
data "aws_iam_policy_document" "connector_operator_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    # aws:SourceAccount などの条件は付けない。Network Connector のサービスは条件キーを渡さないようで、
    # 条件を付けると "unable to assume the provided NetworkConnectorOperatorRole" で作成に失敗する
    # （公式ドキュメントと AWS SAM が生成する信頼ポリシーも条件なし）
  }
}

resource "aws_iam_role" "connector_operator" {
  name               = "${var.project}-connector-operator"
  assume_role_policy = data.aws_iam_policy_document.connector_operator_assume.json
}

data "aws_iam_policy_document" "connector_operator" {
  statement {
    sid     = "CreateENI"
    actions = ["ec2:CreateNetworkInterface"]
    resources = concat(
      ["arn:aws:ec2:${var.region}:${local.account_id}:network-interface/*"],
      [for subnet in aws_subnet.private : subnet.arn],
      [aws_security_group.web_connector.arn],
    )
  }

  statement {
    sid       = "TagENI"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:aws:ec2:${var.region}:${local.account_id}:network-interface/*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:ManagedResourceOperator"
      values   = ["network-connectors.lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "connector_operator" {
  name   = "manage-connector-enis"
  role   = aws_iam_role.connector_operator.id
  policy = data.aws_iam_policy_document.connector_operator.json
}

resource "aws_lambdacore_network_connector" "web" {
  name          = "${var.project}-web"
  operator_role = aws_iam_role.connector_operator.arn

  configuration {
    vpc_egress_configuration {
      subnet_ids                        = [for subnet in aws_subnet.private : subnet.id]
      security_group_ids                = [aws_security_group.web_connector.id]
      network_protocol                  = "IPv4"
      associated_compute_resource_types = ["WebFunction"]
    }
  }

  # ENI の作成には最大 10 分ほどかかる
  timeouts {
    create = "20m"
    update = "20m"
    delete = "20m"
  }

  depends_on = [time_sleep.connector_operator_propagation]
}

# IAM ロールの作成直後は、ほかのサービスから引き受けられるようになるまで時間がかかる。
# 待たずに Connector を作ると、ロールを引き受けられずに失敗することがある
resource "time_sleep" "connector_operator_propagation" {
  create_duration = "30s"

  triggers = {
    role_arn    = aws_iam_role.connector_operator.arn
    policy_hash = sha256(aws_iam_role_policy.connector_operator.policy)
  }
}
