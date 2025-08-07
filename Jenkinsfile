pipeline {
  agent any

  environment {
    REGISTRY = 'ghcr.io'
    IMAGE_NAME = 'tariqasifi/sportstore'   // Jouw GHCR image path
  }

  triggers {
    githubPush()
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
      }
    }

    stage('Build .NET') {
      steps {
        sh 'dotnet build'
      }
    }

    stage('Test') {
      steps {
        sh 'dotnet test'
      }
    }

    stage('Docker Login') {
      steps {
        withCredentials([string(credentialsId: 'Token-GHCR', variable: 'GITHUB_TOKEN')]) {
          sh 'echo $GITHUB_TOKEN | docker login ghcr.io -u tariqasifi --password-stdin'
        }
      }
    }

    stage('Generate Tag') {
      steps {
        script {
          def date = new Date().format("yyyyMMdd-HHmmss", TimeZone.getTimeZone('Europe/Brussels'))
          def branch = env.GIT_BRANCH?.replaceAll('origin/', '') ?: 'main'
          env.IMAGE_TAG = "${branch}-${date}"
          echo "🔖 Generated image tag: ${env.IMAGE_TAG}"
        }
      }
    }

    stage('Docker Build & Push') {
      steps {
        dir('src') {
          sh """
            # Build image met unieke tag
            docker build -t ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} .

            # Push tagged image
            docker push ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}

            # Tag ook als 'latest' en push die
            docker tag ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} ${REGISTRY}/${IMAGE_NAME}:latest
            docker push ${REGISTRY}/${IMAGE_NAME}:latest
          """
        }
      }
    }
  }
}
