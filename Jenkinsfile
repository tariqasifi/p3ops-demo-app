pipeline {
  agent any

  environment {
    REGISTRY = 'ghcr.io'
    IMAGE_NAME = 'tariqasifi/sportstore'
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

  stage('Restore') {
    steps {
      sh 'dotnet restore src/Server/Server.csproj'
    }
  }

    stage('Build .NET') {
      steps {
        sh 'dotnet build'
      }
    }

    stage('Test') {
      steps {
        sh '''
        dotnet restore tests/Domain.Tests/Domain.Tests.csproj
        dotnet test tests/Domain.Tests/Domain.Tests.csproj
         '''
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
          echo "✅ Generated image tag: ${env.IMAGE_TAG}"
        }
      }
    }

    stage('Docker Build & Push') {
      steps {
        sh """
          docker build -t ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} -f src/Dockerfile .

          docker push ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}

          docker tag ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} ${REGISTRY}/${IMAGE_NAME}:latest
          docker push ${REGISTRY}/${IMAGE_NAME}:latest
        """
      }
    }
  }
}
