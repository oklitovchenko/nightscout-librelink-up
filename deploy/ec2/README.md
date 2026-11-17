# EC2 deployment

The image packages these files under `/opt/deploy`. Systems Manager
extracts them from the selected image and runs `deploy.sh` on EC2.
The script reads the requested settings version from Parameter Store,
starts the container, and restores the previous release on failure.
