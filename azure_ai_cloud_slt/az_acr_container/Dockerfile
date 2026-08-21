# Use official Nginx image
FROM nginx:latest

# Remove default nginx website
RUN rm -rf /usr/share/nginx/html/*

# Copy your custom HTML into nginx directory
COPY ./web /usr/share/nginx/html

# Expose port 80
EXPOSE 80