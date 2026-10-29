# Smoke-test fixture: head code that tries to plant symlinks and an oversized file in the
# runner's output directory during plan, so that the host would copy or print a file of its
# own, or fill its disk, through the record. The runner must export none of them.
terraform {
  required_version = ">= 1.5.7"

  required_providers {
    external = {
      source  = "hashicorp/external"
      version = ">= 2.0"
    }
  }
}

data "external" "plant_links" {
  program = [
    "/bin/sh", "-c",
    "ln -sf /etc/passwd /work/out/status; ln -sf /etc/hostname /work/out/plan.log; ln -sf /etc/passwd /work/out/extra; head -c 6000000 /dev/zero > /work/out/probe-init.log; echo '{}'",
  ]
}
