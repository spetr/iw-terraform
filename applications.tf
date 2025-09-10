############################################
# AWS Applications (Resource Groups)
#
# Creates a single AWS Resource Group that shows up as an "Application"
# in the AWS console, grouping all resources tagged with the current
# Project and Environment (set in provider default_tags).
############################################

resource "aws_resourcegroups_group" "application_all" {
  name        = "${var.project}-${var.environment}-application"
  description = "${var.project}-${var.environment}-application aggregating all tagged resources"

  # Query groups all resources that carry our default tags
  resource_query {
    type = "TAG_FILTERS_1_0"
    query = jsonencode({
      ResourceTypeFilters = [
        "AWS::AllSupported"
      ]
      TagFilters = [
        {
          Key    = "Project"
          Values = [var.project]
        },
        {
          Key    = "Environment"
          Values = [var.environment]
        }
      ]
    })
  }

  tags = {
    Name = "${var.project}-${var.environment}-application"
  }
}
