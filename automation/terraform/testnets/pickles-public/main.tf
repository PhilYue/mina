terraform {
  required_version = "~> 0.12.0"
  backend "s3" {
    key     = "terraform-pickles-pickles.tfstate"
    encrypt = true
    region  = "us-west-2"
    bucket  = "o1labs-terraform-state"
    acl     = "bucket-owner-full-control"
  }
}

provider "aws" {
  region = "us-west-2"
}

provider "google" {
  alias   = "google-us-east4"
  project = "o1labs-192920"
  region  = "us-east4"
  zone    = "us-east4-c"
}

provider "google" {
  alias   = "google-us-east1"
  project = "o1labs-192920"
  region  = "us-east1"
  zone    = "us-east1-b"
}

provider "google" {
  alias   = "google-us-central1"
  project = "o1labs-192920"
  region  = "us-central1"
  zone    = "us-central1-c"
}

locals {
  testnet_name = "pickles-public"
  coda_image = "gcr.io/o1labs-192920/coda-daemon:0.0.16-beta7-hard-fork-test-11-12-2020-3bacbd4"
  coda_archive_image = "gcr.io/o1labs-192920/coda-archive:0.0.16-beta7-develop-4108f65"
  seed_region = "us-central1"
  seed_zone = "us-central1-c"
  seed_discovery_keypairs = [
  "CAESQBEHe2zCcQDHcSaeIydGggamzmTapdCS8SP0hb5FWvYhe9XEygmlUGV4zNu2P8zAIba4X84Gm4usQFLamjRywA8=,CAESIHvVxMoJpVBleMzbtj/MwCG2uF/OBpuLrEBS2po0csAP,12D3KooWJ9mNdbUXUpUNeMnejRumKzmQF15YeWwAPAhTAWB6dhiv",
  "CAESQO+8qvMqTaQEX9uh4NnNoyOy4Xwv3U80jAsWweQ1J37AVgx7kgs4pPVSBzlP7NDANP1qvSvEPOTh2atbMMUO8EQ=,CAESIFYMe5ILOKT1Ugc5T+zQwDT9ar0rxDzk4dmrWzDFDvBE,12D3KooWFcGGeUmbmCNq51NBdGvCWjiyefdNZbDXADMK5CDwNRm5" ]

  runtime_config = <<EOT
    ${file("./genesis_ledger_fork_11-12-2020.json")}
  EOT
}


module "testnet_east" {
  providers = { google = google.google-us-central1 }
  source    = "../../modules/kubernetes/testnet"

  gcloud_seeds = [ module.seed_one, module.seed_two ]

  cluster_name          = "coda-infra-central1"
  cluster_region        = "us-central1"
  testnet_name          = local.testnet_name

  coda_image            = local.coda_image
  coda_archive_image    = local.coda_archive_image
  coda_agent_image      = "codaprotocol/coda-user-agent:0.1.5"
  coda_bots_image       = "codaprotocol/coda-bots:0.0.13-beta-1"
  coda_points_image     = "codaprotocol/coda-points-hack:32b.4"

  coda_faucet_amount    = "10000000000"
  coda_faucet_fee       = "100000000"

  mina_archive_schema = "https://raw.githubusercontent.com/MinaProtocol/mina/4108f65508d97427d9572e50e0e382afbb7b3eb6/src/app/archive/create_schema.sql"

  runtime_config = local.runtime_config

  additional_seed_peers = [
    "/dns4/seed-one.${local.testnet_name}.o1test.net/tcp/10001/p2p/${split(",", local.seed_discovery_keypairs[0])[2]}",
    "/dns4/seed-two.${local.testnet_name}.o1test.net/tcp/10001/p2p/${split(",", local.seed_discovery_keypairs[1])[2]}"
  ]

  seed_zone = local.seed_zone
  seed_region = local.seed_region

  log_level              = "Debug"
  log_txn_pool_gossip    = true

  block_producer_key_pass = "naughty blue worm"
  block_producer_starting_host_port = 10501

  block_producer_configs = concat(
    [
      for i in range(15): {
        name                   = "whale-block-producer-${i + 1}"
        class                  = "whale"
        id                     = i + 1
        private_key_secret     = "online-whale-account-${i + 1}-key"
        enable_gossip_flooding = false
        run_with_user_agent    = false
        run_with_bots          = false
        enable_peer_exchange   = true
        isolated               = false
      }
    ],
    [
      for i in range(1): {
        name                   = "fish-block-producer-${i + 1}"
        class                  = "fish"
        id                     = i + 1
        private_key_secret     = "online-fish-account-${i + 1}-key"
        enable_gossip_flooding = false
        run_with_user_agent    = true
        run_with_bots          = false
        enable_peer_exchange   = false
        isolated               = false
      }
    ]
  )

  snark_worker_replicas = 15
  snark_worker_fee      = "0.025"
  snark_worker_public_key = "B62qk4nuKn2U5kb4dnZiUwXeRNtP1LncekdAKddnd1Ze8cWZnjWpmMU"
  snark_worker_host_port = 10401

  agent_min_fee = "0.05"
  agent_max_fee = "0.1"
  agent_min_tx = "0.0015"
  agent_max_tx = "0.0015"
  agent_send_every_mins = "1"
}
