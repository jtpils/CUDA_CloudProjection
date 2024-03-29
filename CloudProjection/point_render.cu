#include "point_render.cuh"
#include <stdio.h>

#include "helper_math.h"


struct Matrix4x4
{
public:
	float4 col[4];
	__device__ __forceinline__
		Matrix4x4()
	{
		col[0] = col[1] = col[2] = col[3] = make_float4(0, 0, 0, 0);
	}
	__device__ __forceinline__
		Matrix4x4(float3 a, float3 b, float3 c, float3 d)
	{
		col[0].x = a.x;
		col[0].y = a.y;
		col[0].z = a.z;
		col[0].w = 0;

		col[1].x = b.x;
		col[1].y = b.y;
		col[1].z = b.z;
		col[1].w = 0;

		col[2].x = c.x;
		col[2].y = c.y;
		col[2].z = c.z;
		col[2].w = 0;

		col[3].x = d.x;
		col[3].y = d.y;
		col[3].z = d.z;
		col[3].w = 1;
	}

	__device__ __forceinline__
		Matrix4x4 transpose() const
	{
		Matrix4x4 res;

		res.col[0].x = col[0].x;
		res.col[0].y = col[1].x;
		res.col[0].z = col[2].x;
		res.col[0].w = col[3].x;

		res.col[1].x = col[0].y;
		res.col[1].y = col[1].y;
		res.col[1].z = col[2].y;
		res.col[1].w = col[3].y;

		res.col[2].x = col[0].z;
		res.col[2].y = col[1].z;
		res.col[2].z = col[2].z;
		res.col[2].w = col[3].z;

		res.col[3].x = 0;
		res.col[3].y = 0;
		res.col[3].z = 0;
		res.col[3].w = 1;
		return res;

	}
	__device__ __forceinline__
		Matrix4x4 inv() const
	{
		Matrix4x4 res;
		res.col[0].x = col[0].x;
		res.col[0].y = col[1].x;
		res.col[0].z = col[2].x;
		res.col[0].w = 0;

		res.col[1].x = col[0].y;
		res.col[1].y = col[1].y;
		res.col[1].z = col[2].y;
		res.col[1].w = 0;

		res.col[2].x = col[0].z;
		res.col[2].y = col[1].z;
		res.col[2].z = col[2].z;
		res.col[2].w = 0;

		res.col[3].x = -dot(col[0], col[3]);
		res.col[3].y = -dot(col[1], col[3]);
		res.col[3].z = -dot(col[2], col[3]);
		res.col[3].w = 1;
		return res;
	}

	__device__ __forceinline__
		static	Matrix4x4 RotateX(float rad)
	{
		Matrix4x4 res;
		res.col[0].x = 1;
		res.col[0].y = 0;
		res.col[0].z = 0;
		res.col[0].w = 0;

		res.col[1].x = 0;
		res.col[1].y = cos(rad);
		res.col[1].z = sin(rad);
		res.col[1].w = 0;

		res.col[2].x = 0;
		res.col[2].y = -sin(rad);
		res.col[2].z = cos(rad);
		res.col[2].w = 0;

		res.col[3].x = 0;
		res.col[3].y = 0;
		res.col[3].z = 0;
		res.col[3].w = 1;
		return res;
	}
};



typedef struct CamPoseNode
{
	float3 norm, Xaxis, Yaxis, offset;
	__device__ __forceinline__
		Matrix4x4 getRT() const
	{
		return Matrix4x4(Xaxis, Yaxis, norm, offset);
	}

}CamPose;



typedef struct CamIntrinsic
{
	float3 r[3];

	__device__ __forceinline__
		Matrix4x4 getMatrix(float scale = 1.0) const
	{
		Matrix4x4 res;
		res.col[0].x = r[0].x * scale;
		res.col[0].y = r[1].x * scale;
		res.col[0].z = r[2].x * scale;
		res.col[0].w = 0;

		res.col[1].x = r[0].y * scale;
		res.col[1].y = r[1].y * scale;
		res.col[1].z = r[2].y * scale;
		res.col[1].w = 0;

		res.col[2].x = r[0].z * scale;
		res.col[2].y = r[1].z * scale;
		res.col[2].z = r[2].z;
		res.col[2].w = 0;

		res.col[3].x = 0;
		res.col[3].y = 0;
		res.col[3].z = 0;
		res.col[3].w = 1;
		return res;
	}
	__device__ __forceinline__
		float4 PointInverse(float x, float y, float scale = 1.0)
	{
		float xx = (x - r[0].z * scale) / (r[0].x * scale);
		float yy = (y - r[1].z * scale) / (r[1].y * scale);
		return make_float4(xx, yy, 1, 1);
	}

};


namespace math
{
	__device__ __forceinline__
	float4 MatrixMul(const Matrix4x4& mat, float4& x)
	{
		Matrix4x4 res = mat.transpose();
		float4 ans;
		ans.x = dot(res.col[0], x);
		ans.y = dot(res.col[1], x);
		ans.z = dot(res.col[2], x);
		ans.w = dot(res.col[3], x);

		ans = ans / ans.w;
		return ans;
	}
}


__global__
void DepthProject(float3 * point_clouds, int num_points,
	CamIntrinsic* tar_intrinsic, CamPose* tar_Pose, int tar_width, int tar_height,
	int * mutex_map, float near, float far, float max_splatting_size,
	float* out_depth, int* out_index)
{
	int ids = blockDim.x * blockIdx.x + threadIdx.x; //  index of point


	if (ids > num_points) 
		return;


	// Cache camera parameters
	 CamPose _tarcamPose = *tar_Pose;
	 CamIntrinsic _tarcamIntrinsic = *tar_intrinsic;


	float4 p = make_float4(point_clouds[ids], 1.0);

	Matrix4x4 camT = _tarcamPose.getRT();
	camT = camT.inv();
	float4 camp = math::MatrixMul(camT, p);



	float tdepth = camp.z;

	if (tdepth < 0)
		return;
	camp = math::MatrixMul(_tarcamIntrinsic.getMatrix(), camp);

	camp = camp / camp.w;
	camp = camp / camp.z;



	// splatting radius

	float rate = (tdepth - near) / (far - near);
	rate = 1.0 - rate;
	rate = max(rate, 0.0);
	rate = min(rate, 1.0);
	

	float radius = max_splatting_size * rate;

	// splatting
	for (int xx = round(camp.x - radius); xx <= round(camp.x + radius); ++xx)
	{
		for (int yy = round(camp.y - radius); yy <= round(camp.y + radius); ++yy)
		{
			if (xx < 0 || xx >= tar_width || yy < 0 || yy >= tar_height)
				return;

			int ind = yy * tar_width + xx ;

			if (out_depth[ind] > 0 && out_depth[ind] <= tdepth)
				continue;

			bool isSet = false;
			do
			{
				if ((isSet = atomicCAS(mutex_map + ind, 0, 1)) == false)
				{
					// critical section goes here
					if (out_depth[ind] > tdepth || out_depth[ind]==0)
					{
						out_depth[ind] = tdepth;
						out_index[ind] = ids + 1; // 0 denote empty
					}
				}
				if (isSet)
				{
					mutex_map[ind] = 0;
				}
			} while (!isSet);

		}
	}

}

void GPU_PCPR(
	torch::Tensor in_points, //(num_points,3)
	torch::Tensor tar_intrinsic, torch::Tensor tar_Pose, 
	float near, float far, float max_splatting_size,
	torch::Tensor out_depth, torch::Tensor out_index) // (tar_height ,tar_width)
{
	const auto num_points = in_points.size(0);

	dim3 dimBlock(256,1);
	dim3 dimGrid(num_points / dimBlock.x + 1, 1);

	int tar_height = out_depth.size(0);
	int tar_width = out_depth.size(1);

	int *mutex_map;
	cudaMalloc(&mutex_map, sizeof(int) * tar_width *tar_height);
	cudaMemset(mutex_map, 0, tar_width * tar_height * sizeof(int));


	DepthProject << <dimGrid, dimBlock >> > (
		(float3*)in_points.data<float>(), num_points,
		(CamIntrinsic*)tar_intrinsic.data<float>(),(CamPose*)tar_Pose.data<float>(), tar_width, tar_height,
		mutex_map, near, far, max_splatting_size,
		out_depth.data<float>(), out_index.data<int>() );

	cudaFree(mutex_map);
}



__global__
void PCPR_backward(float* grad_feature_image, int* index, int* num_points,
	float* out_grad_feature_points, float* out_grad_default_feature,
	int feature_dim, int num_batch, int width, int height, int total_sum)
{
	int x = blockDim.x * blockIdx.x + threadIdx.x; // width
	int y = blockDim.y * blockIdx.y + threadIdx.y; // height


	if (y >= height || x >= width)
		return;

	__shared__ int _num_points[16];


	if (threadIdx.x < num_batch && threadIdx.y == 0) {
		_num_points[threadIdx.x] = *(num_points + threadIdx.x);
	}
	__syncthreads();


	int beg = 0;
	for (int i = 0; i < num_batch; ++i)
	{
		float* grad_feature_subimage = grad_feature_image + feature_dim * width * height * i
			+ y * width + x;

		int subindex = index[width * height * i + y * width + x];


		int num_points_sub = _num_points[i];

		int point_index = beg + subindex;

		float* out_grad_feature_points_sub = out_grad_feature_points + point_index;

		if (subindex == _num_points[i])
		{ // default feature
			for (int j = 0; j < feature_dim; ++j)
			{
				atomicAdd(out_grad_default_feature + j, grad_feature_subimage[j * width * height]);
			}
		}
		else
		{ // accumulate point gradient
			for (int j = 0; j < feature_dim; ++j)
			{
				atomicAdd(out_grad_feature_points_sub + j * total_sum, grad_feature_subimage[j * width * height]);
			}
		}

		beg += _num_points[i];
	}

}




void GPU_PCPR_backward(
    torch::Tensor grad_feature_image, //(batch, dim, height, width)
    torch::Tensor index,        //(batch, height, width)
    torch::Tensor num_points,     // (batch)
    torch::Tensor out_grad_feature_points, // (dim, total points)
	torch::Tensor out_grad_default_feature, // (dim, 1)
	int total_num
    )
{
	int num_batch = num_points.size(0);
	int feature_dim = out_grad_feature_points.size(0);

	cudaMemset(out_grad_feature_points.data<float>(), 0, sizeof(float)*feature_dim*out_grad_feature_points.size(1));
	cudaMemset(out_grad_default_feature.data<float>(), 0, sizeof(float)*feature_dim*out_grad_default_feature.size(1));

	int height = index.size(1);
	int width = index.size(2);

	dim3 dimBlock(32,32,1);
	dim3 dimGrid(height / dimBlock.x + 1, width / dimBlock.y + 1,1);


	PCPR_backward<< <dimGrid, dimBlock >> >(grad_feature_image.data<float>(), index.data<int>(), num_points.data<int>(),
		  out_grad_feature_points.data<float>(), out_grad_default_feature.data<float>(),
		  feature_dim, num_batch, width, height, total_num);


}

