FROM --platform=linux/amd64 alpine:latest

# Install required packages
RUN apk add --no-cache \
    bash \
    curl \
    bc \
    util-linux \
    jq \
    procps

# Create app directory
WORKDIR /app

# Copy the script
COPY traffic-generator.sh .

# Make script executable and verify it exists
RUN chmod +x traffic-generator.sh && \
    ls -la traffic-generator.sh && \
    cat traffic-generator.sh

# Set default environment variables
ENV BATCH_SIZE=3 \
    STATS_INTERVAL=60 \
    METRICS_FILE="/tmp/load_test_metrics.txt" \
    ALB_URL="" \
    API_PATH="/apps/cart"

CMD ["./traffic-generator.sh"]
