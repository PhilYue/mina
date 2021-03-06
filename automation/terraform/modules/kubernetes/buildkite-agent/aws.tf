resource "aws_iam_user" "buildkite_aws_user" {
  name = "buildkite-${var.cluster_name}"
  path = "/service-accounts/"

  force_destroy = true
}

resource "aws_iam_access_key" "buildkite_aws_key" {
  user    = aws_iam_user.buildkite_aws_user.name
}

data "aws_iam_policy_document" "buildkite_aws_policydoc" {
  statement {
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:ListSecrets",
      "secretsmanager:TagResource"
    ]

    effect = "Allow"

    # TODO: narrow to buildkite agent pipeline specific set of secrets
    resources = [
      "*",
    ]
  }

  statement {
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:PutObjectAcl",
      "s3:DeleteObject"
    ]

    effect = "Allow"

    resources = [
      "arn:aws:s3:::packages.o1test.net/*",
      "arn:aws:s3:::snark-keys.o1test.net/*"
    ]
  }

  statement {
    actions = [
      "s3:GetObject",
      "s3:PutObject"
    ]

    effect = "Allow"

    resources = [
      "arn:aws:s3:::o1labs-terraform-state/*",
      "arn:aws:s3:::o1labs-terraform-state-destination/*"
    ]
  }

  statement {
    actions = [ "s3:ListBucket" ]

    effect = "Allow"

    resources = [
      "arn:aws:s3:::o1labs-terraform-state",
      "arn:aws:s3:::o1labs-terraform-state-destination"
    ]
  }
}

resource "aws_iam_user_policy" "buildkite_aws_policy" {
  name = "buildkite_agent_policy"
  user = aws_iam_user.buildkite_aws_user.name

  policy = data.aws_iam_policy_document.buildkite_aws_policydoc.json
}

data "aws_secretsmanager_secret" "buildkite_docker_token_metadata" {
  name = "o1bot/docker/ci-access-token"
}

data "aws_secretsmanager_secret_version" "buildkite_docker_token" {
  secret_id = "${data.aws_secretsmanager_secret.buildkite_docker_token_metadata.id}"
}

data "aws_secretsmanager_secret" "buildkite_api_token_metadata" {
  name = "buildkite/agent/api-token"
}

data "aws_secretsmanager_secret_version" "buildkite_api_token" {
  secret_id = "${data.aws_secretsmanager_secret.buildkite_api_token_metadata.id}"
}
