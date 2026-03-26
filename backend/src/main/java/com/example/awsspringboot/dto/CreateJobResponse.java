package com.example.awsspringboot.dto;

import com.example.awsspringboot.model.JobStatus;

public record CreateJobResponse(String jobId, JobStatus status) {}
