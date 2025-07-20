# gcp-mixed-backends-tf

## Enable APIs
```sh
# in google cloud shell
gcloud services enable \
  compute.googleapis.com \
  container.googleapis.com \
  run.googleapis.com \
  --project=$DEVSHELL_PROJECT_ID
```