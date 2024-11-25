#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>
#include <cuda.h>

// Kernel to compute the next generation
__global__ void next_generation_shared(int *grid, int *new_grid, int rows, int cols) {
    // Assuming a block size of 16x16
    __shared__ int shared_grid[18][18];  // 2 extra rows/columns for ghost cells

    int tx = threadIdx.x;
    int ty = threadIdx.y;
    int bx = blockIdx.x;
    int by = blockIdx.y;

    int global_x = bx * blockDim.x + tx;
    int global_y = by * blockDim.y + ty;

    // Load main cell and its neighborhood into shared memory
    if (global_x < cols && global_y < rows) {
        // Load the main cell
        shared_grid[ty+1][tx+1] = grid[global_y * cols + global_x];

        // Load halo cells
        // Top row
        if (ty == 0) {
            if (global_y > 0)
                shared_grid[0][tx+1] = grid[(global_y-1) * cols + global_x];
            
            // Corner cells
            if (tx == 0 && global_x > 0 && global_y > 0)
                shared_grid[0][0] = grid[(global_y-1) * cols + (global_x-1)];
            
            if (tx == blockDim.x-1 && global_x < cols-1 && global_y > 0)
                shared_grid[0][tx+2] = grid[(global_y-1) * cols + (global_x+1)];
        }

        // Bottom row
        if (ty == blockDim.y-1) {
            if (global_y < rows-1)
                shared_grid[ty+2][tx+1] = grid[(global_y+1) * cols + global_x];
            
            // Corner cells
            if (tx == 0 && global_x > 0 && global_y < rows-1)
                shared_grid[ty+2][0] = grid[(global_y+1) * cols + (global_x-1)];
            
            if (tx == blockDim.x-1 && global_x < cols-1 && global_y < rows-1)
                shared_grid[ty+2][tx+2] = grid[(global_y+1) * cols + (global_x+1)];
        }

        // Left column
        if (tx == 0 && global_x > 0)
            shared_grid[ty+1][0] = grid[global_y * cols + (global_x-1)];

        // Right column
        if (tx == blockDim.x-1 && global_x < cols-1)
            shared_grid[ty+1][tx+2] = grid[global_y * cols + (global_x+1)];
    }

    // Synchronize to ensure all shared memory is loaded
    __syncthreads();

    // Compute next state
    if (global_x >= 1 && global_x < cols-1 && global_y >= 1 && global_y < rows-1) {
        // Count live neighbors using shared memory
        int neighbors = 
            shared_grid[ty][tx] + 
            shared_grid[ty][tx+1] + 
            shared_grid[ty][tx+2] +
            shared_grid[ty+1][tx] + 
            shared_grid[ty+1][tx+2] +
            shared_grid[ty+2][tx] + 
            shared_grid[ty+2][tx+1] + 
            shared_grid[ty+2][tx+2];

        // Apply Game of Life rules
        if (neighbors <= 1 || neighbors >= 4)
            new_grid[global_y * cols + global_x] = 0;  // Dies
        else if (neighbors == 3)
            new_grid[global_y * cols + global_x] = 1;  // Born
        else
            new_grid[global_y * cols + global_x] = shared_grid[ty+1][tx+1];  // Stays the same
    }
}

// Function to initialize the grid with random values
void initialize_grid(int *grid, int rows, int cols) {
    srand(42);  // Fixed seed for reproducibility
    for (int i = 1; i < rows - 1; i++) {
        for (int j = 1; j < cols - 1; j++) {
            grid[i * cols + j] = rand() % 2;
        }
    }
}

// Output function
void outputtofile(char *output_file, int *grid, int rows, int cols) {
    FILE *file = fopen(output_file, "w");
    for (int i = 1; i < rows - 1; i++) {
        for (int j = 1; j < cols - 1; j++) {
            fprintf(file, "%i ", grid[i * cols + j]);
        }
        fprintf(file, "\n");
    }
    fclose(file);
}

// Function to get the current time in seconds
double get_time() {
    struct timeval tval;
    gettimeofday(&tval, NULL);
    return (double)tval.tv_sec + (double)tval.tv_usec / 1000000.0;
}

// Main function
int main(int argc, char **argv) {
    if (argc != 6) {
        printf("Usage: %s <dimensions (int)> <max_generations (int)> <num_threads (int)> <stagnationcheck (boolean 1 or 0)> <output directory (string)>\n", argv[0]);
        exit(-1);
    }

    // Parse command line arguments
    int dimensions = atoi(argv[1]);
    int max_generations = atoi(argv[2]);
    int block_size = atoi(argv[3]);
    int stagnationcheck = atoi(argv[5]);
    // Boolean for turning on and off stagnation check

    int rows = dimensions + 2;  // Adding ghost rows
    int cols = dimensions + 2;

    size_t grid_size = rows * cols * sizeof(int);

    // Allocate memory for grids on host
    int *host_grid = (int *)malloc(grid_size);
    int *host_new_grid = (int *)malloc(grid_size);

    // Initialize the grid
    initialize_grid(host_grid, rows, cols);

    // Allocate memory for grids on device
    int *dev_grid, *dev_new_grid;
    cudaMalloc((void **)&dev_grid, grid_size);
    cudaMalloc((void **)&dev_new_grid, grid_size);

    // Copy initial grid to device
    cudaMemcpy(dev_grid, host_grid, grid_size, cudaMemcpyHostToDevice);

    // Set up block and grid dimensions
    dim3 block_dim(block_size, block_size);
    dim3 grid_dim((cols + block_size - 1) / block_size, (rows + block_size - 1) / block_size);

    // Main simulation loop
    for (int gen = 0; gen < max_generations; gen++) {
        next_generation_shared<<<grid_dim, block_dim>>>(dev_grid, dev_new_grid, rows, cols);

        // Swap grids
        int *temp = dev_grid;
        dev_grid = dev_new_grid;
        dev_new_grid = temp;

        // Optional: Check for stagnation (if enabled)
        if (stagnationcheck) {
            // Add stagnation check logic here if required.
        }
    }

    // Copy final grid back to host
    cudaMemcpy(host_grid, dev_grid, grid_size, cudaMemcpyDeviceToHost);

    // Output file and directory (format output_N_N_gen_threads.txt)
    char output_file[200];
    sprintf(output_file, "%s/output%s_%s_%s.txt", argv[4], argv[1], argv[2], argv[3]);
    outputtofile(output_file, host_grid, rows, cols);

    // Free memory on device
    cudaFree(dev_grid);
    cudaFree(dev_new_grid);

    // Free memory on host
    free(host_grid);
    free(host_new_grid);

    return 0;
}