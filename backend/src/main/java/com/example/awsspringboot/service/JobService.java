package com.example.awsspringboot.service;

import com.example.awsspringboot.model.JobItem;
import com.example.awsspringboot.model.JobStatus;
import jakarta.annotation.PreDestroy;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.model.GetItemRequest;
import software.amazon.awssdk.services.dynamodb.model.PutItemRequest;
import software.amazon.awssdk.services.dynamodb.model.UpdateItemRequest;
import software.amazon.awssdk.services.sqs.SqsClient;
import software.amazon.awssdk.services.sqs.model.DeleteMessageRequest;
import software.amazon.awssdk.services.sqs.model.Message;
import software.amazon.awssdk.services.sqs.model.ReceiveMessageRequest;
import software.amazon.awssdk.services.sqs.model.SendMessageRequest;

@Service
public class JobService {
  private static final String FIELD_JOB_ID = "jobId";
  private static final String FIELD_MESSAGE = "message";
  private static final String FIELD_STATUS = "status";
  private static final String FIELD_CREATED_AT = "createdAt";
  private static final String FIELD_UPDATED_AT = "updatedAt";
  private static final String FIELD_PROCESSING_AT = "processingAt";
  private static final String FIELD_PROCESSED_AT = "processedAt";
  private static final String FIELD_RESULT = "result";

  private final ConcurrentMap<String, JobItem> jobs = new ConcurrentHashMap<>();
  private final ScheduledExecutorService scheduler = Executors.newScheduledThreadPool(2);
  private final boolean awsEnabled;
  private final boolean queuePollingEnabled;
  private final String tableName;
  private final String queueUrl;
  private final DynamoDbClient dynamoDbClient;
  private final SqsClient sqsClient;

  public JobService(
      @Value("${aws.jobs.enabled:false}") boolean awsEnabled,
      @Value("${aws.jobs.queuePollingEnabled:true}") boolean queuePollingEnabled,
      @Value("${aws.jobs.tableName:jobs}") String tableName,
      @Value("${aws.jobs.queueUrl:}") String queueUrl) {
    this.awsEnabled = awsEnabled;
    this.queuePollingEnabled = queuePollingEnabled;
    this.tableName = tableName;
    this.queueUrl = queueUrl == null ? "" : queueUrl.trim();

    if (this.awsEnabled) {
      this.dynamoDbClient = DynamoDbClient.create();
      this.sqsClient = SqsClient.create();
      if (this.queuePollingEnabled) {
        scheduler.scheduleAtFixedRate(this::pollQueue, 500, 1000, TimeUnit.MILLISECONDS);
      }
    } else {
      this.dynamoDbClient = null;
      this.sqsClient = null;
    }
  }

  public JobItem createJob(String message) {
    String now = Instant.now().toString();
    String jobId = UUID.randomUUID().toString();

    JobItem item = new JobItem();
    item.setJobId(jobId);
    item.setMessage(message);
    item.setStatus(JobStatus.PENDING);
    item.setCreatedAt(now);
    item.setUpdatedAt(now);

    if (awsEnabled) {
      createAwsJob(item);
      return item;
    }

    jobs.put(jobId, item);

    scheduler.schedule(() -> markProcessing(jobId), 300, TimeUnit.MILLISECONDS);
    scheduler.schedule(() -> markCompleted(jobId), 1800, TimeUnit.MILLISECONDS);

    return item;
  }

  public Optional<JobItem> getJob(String jobId) {
    if (awsEnabled) {
      return getAwsJob(jobId);
    }

    return Optional.ofNullable(jobs.get(jobId));
  }

  public String getMode() {
    return awsEnabled ? "AWS_DYNAMODB_SQS" : "LOCAL_MEMORY";
  }

  private void markProcessing(String jobId) {
    jobs.computeIfPresent(jobId, (id, item) -> {
      String now = Instant.now().toString();
      item.setStatus(JobStatus.PROCESSING);
      item.setProcessingAt(now);
      item.setUpdatedAt(now);
      return item;
    });
  }

  private void markCompleted(String jobId) {
    jobs.computeIfPresent(jobId, (id, item) -> {
      String now = Instant.now().toString();
      item.setStatus(JobStatus.COMPLETED);
      item.setProcessedAt(now);
      item.setUpdatedAt(now);
      item.setResult("Processed message for job " + jobId);
      return item;
    });
  }

  private void createAwsJob(JobItem item) {
    assertAwsQueueConfigured();

    Map<String, AttributeValue> attributes = Map.of(
        FIELD_JOB_ID, AttributeValue.builder().s(item.getJobId()).build(),
        FIELD_MESSAGE, AttributeValue.builder().s(item.getMessage()).build(),
        FIELD_STATUS, AttributeValue.builder().s(item.getStatus().name()).build(),
        FIELD_CREATED_AT, AttributeValue.builder().s(item.getCreatedAt()).build(),
        FIELD_UPDATED_AT, AttributeValue.builder().s(item.getUpdatedAt()).build());

    PutItemRequest putRequest = PutItemRequest.builder()
        .tableName(tableName)
        .item(attributes)
        .build();
    dynamoDbClient.putItem(putRequest);

    sqsClient.sendMessage(SendMessageRequest.builder()
        .queueUrl(queueUrl)
        .messageBody(item.getJobId())
        .build());
  }

  private Optional<JobItem> getAwsJob(String jobId) {
    GetItemRequest request = GetItemRequest.builder()
        .tableName(tableName)
        .key(Map.of(FIELD_JOB_ID, AttributeValue.builder().s(jobId).build()))
        .build();
    Map<String, AttributeValue> item = dynamoDbClient.getItem(request).item();
    if (item == null || item.isEmpty()) {
      return Optional.empty();
    }

    JobItem mapped = new JobItem();
    mapped.setJobId(readString(item, FIELD_JOB_ID));
    mapped.setMessage(readString(item, FIELD_MESSAGE));
    mapped.setStatus(JobStatus.valueOf(readString(item, FIELD_STATUS)));
    mapped.setCreatedAt(readString(item, FIELD_CREATED_AT));
    mapped.setUpdatedAt(readString(item, FIELD_UPDATED_AT));
    mapped.setProcessingAt(readString(item, FIELD_PROCESSING_AT));
    mapped.setProcessedAt(readString(item, FIELD_PROCESSED_AT));
    mapped.setResult(readString(item, FIELD_RESULT));
    return Optional.of(mapped);
  }

  private void pollQueue() {
    if (!awsEnabled || queueUrl.isEmpty()) {
      return;
    }

    ReceiveMessageRequest request = ReceiveMessageRequest.builder()
        .queueUrl(queueUrl)
        .maxNumberOfMessages(5)
        .waitTimeSeconds(1)
        .visibilityTimeout(20)
        .build();

    List<Message> messages = sqsClient.receiveMessage(request).messages();
    for (Message message : messages) {
      processAwsJob(message);
    }
  }

  private void processAwsJob(Message message) {
    String jobId = message.body() == null ? "" : message.body().trim();
    if (jobId.isEmpty()) {
      deleteMessage(message.receiptHandle());
      return;
    }

    String processingAt = Instant.now().toString();
    UpdateItemRequest processingRequest = UpdateItemRequest.builder()
        .tableName(tableName)
        .key(Map.of(FIELD_JOB_ID, AttributeValue.builder().s(jobId).build()))
        .updateExpression("SET #status = :status, #processingAt = :processingAt, #updatedAt = :updatedAt")
        .expressionAttributeNames(Map.of(
            "#status", FIELD_STATUS,
            "#processingAt", FIELD_PROCESSING_AT,
            "#updatedAt", FIELD_UPDATED_AT))
        .expressionAttributeValues(Map.of(
            ":status", AttributeValue.builder().s(JobStatus.PROCESSING.name()).build(),
            ":processingAt", AttributeValue.builder().s(processingAt).build(),
            ":updatedAt", AttributeValue.builder().s(processingAt).build()))
        .build();
    dynamoDbClient.updateItem(processingRequest);

    scheduler.schedule(() -> {
      String completedAt = Instant.now().toString();
      UpdateItemRequest completedRequest = UpdateItemRequest.builder()
          .tableName(tableName)
          .key(Map.of(FIELD_JOB_ID, AttributeValue.builder().s(jobId).build()))
          .updateExpression(
              "SET #status = :status, #processedAt = :processedAt, #updatedAt = :updatedAt, #result = :result")
          .expressionAttributeNames(Map.of(
              "#status", FIELD_STATUS,
              "#processedAt", FIELD_PROCESSED_AT,
              "#updatedAt", FIELD_UPDATED_AT,
              "#result", FIELD_RESULT))
          .expressionAttributeValues(Map.of(
              ":status", AttributeValue.builder().s(JobStatus.COMPLETED.name()).build(),
              ":processedAt", AttributeValue.builder().s(completedAt).build(),
              ":updatedAt", AttributeValue.builder().s(completedAt).build(),
              ":result", AttributeValue.builder().s("Processed message for job " + jobId).build()))
          .build();
      dynamoDbClient.updateItem(completedRequest);
      deleteMessage(message.receiptHandle());
    }, 1800, TimeUnit.MILLISECONDS);
  }

  private void assertAwsQueueConfigured() {
    if (queueUrl.isEmpty()) {
      throw new IllegalStateException("AWS_JOBS_QUEUE_URL must be configured when AWS_JOBS_ENABLED=true");
    }
  }

  private void deleteMessage(String receiptHandle) {
    if (receiptHandle == null || receiptHandle.isBlank()) {
      return;
    }
    sqsClient.deleteMessage(DeleteMessageRequest.builder()
        .queueUrl(queueUrl)
        .receiptHandle(receiptHandle)
        .build());
  }

  private String readString(Map<String, AttributeValue> item, String key) {
    AttributeValue value = item.get(key);
    if (value == null) {
      return null;
    }
    return value.s();
  }

  @PreDestroy
  public void shutdown() {
    scheduler.shutdownNow();
    if (dynamoDbClient != null) {
      dynamoDbClient.close();
    }
    if (sqsClient != null) {
      sqsClient.close();
    }
  }
}
