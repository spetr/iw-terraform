terraform {
  # Remote state stored in S3. Configuration is provided via backend.hcl at init time.
  backend "s3" {}
}

